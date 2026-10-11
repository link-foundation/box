#!/usr/bin/env bash
# Reproduce PR 132's GitHub 503 failures without accessing the network.
# Set RECHECK_TEST_SCRIPT to an earlier script to verify the reproducer fails.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const script = process.env.RECHECK_TEST_SCRIPT || 'scripts/ci/recheck-broken-links.mjs';
const recheckModule = await import(pathToFileURL(path.resolve(script)));
const recheckFailures = recheckModule.recheckFailures || recheckModule.recheckUnanswered;

// Drive the actual CLI, including report parsing and GitHub Actions outputs.
async function withFixture(check) {
  const work = await mkdtemp(path.join(os.tmpdir(), 'issue131-links-'));
  const requests = [];
  const server = createServer((req, res) => {
    requests.push(req.url);
    const attempt = requests.filter((url) => url === req.url).length;
    const temporaryStatus = Number(req.url.match(/^\/status-(\d+)$/)?.[1] || 503);
    const status = req.url === '/persistent' ? 503
      : req.url === '/gone' ? 404
      : req.url === '/becomes-gone' ? (attempt === 1 ? 503 : 404)
      : (attempt === 1 ? temporaryStatus : 200);
    res.writeHead(status);
    res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const report = (status, suffix) =>
    `* [${status}] <${base}${suffix}> (at 72:2) | Rejected status code: ${status}\n`;
  const recheck = async (content, budget = '2') => {
    await writeFile(path.join(work, 'report.md'), content);
    await writeFile(path.join(work, 'output'), '');
    await rm(path.join(work, 'recovered'), { force: true });
    const { stdout } = await run(process.execPath,
      [script], {
        env: { ...process.env,
          LYCHEE_OUTPUT: path.join(work, 'report.md'),
          RECOVERED_OUTPUT: path.join(work, 'recovered'),
          GITHUB_OUTPUT: path.join(work, 'output'),
          RECHECK_BUDGET_SECONDS: budget,
          RECHECK_WAIT_MS: '5',
        },
      });
    return {
      stdout,
      output: await readFile(path.join(work, 'output'), 'utf8'),
      recovered: await readFile(path.join(work, 'recovered'), 'utf8')
        .catch((error) => { if (error.code === 'ENOENT') return ''; throw error; }),
    };
  };
  try {
    await check({ base, report, recheck, requests });
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(work, { recursive: true, force: true });
  }
}

test('the two HTTP 503 failures recover only after successful responses', { timeout: 5000 }, async () => {
  await withFixture(async ({ base, report, recheck, requests }) => {
    const result = await recheck(report(503, '/sysbox') + report(503, '/podman'));
    assert.equal(result.output, 'all_recovered=true\n');
    assert.equal(result.recovered, `${base}/sysbox\n${base}/podman\n`);
    assert.deepEqual(requests, ['/sysbox', '/podman', '/sysbox', '/podman']);
  });
});

test('temporary HTTP statuses in numeric markers and error details are retried', { timeout: 5000 }, async () => {
  await withFixture(async ({ report, recheck }) => {
    for (const status of [408, 429, 500, 502, 503, 504]) {
      const result = await recheck(report(status, `/status-${status}`));
      assert.equal(result.output, 'all_recovered=true\n', `HTTP ${status}`);
    }
    const result = await recheck(report(503, '/detail').replace('[503]', '[ERROR]'));
    assert.equal(result.output, 'all_recovered=true\n');
  });
});

test('404s, missing files, and broken fragments remain failures alongside a recovered 503', { timeout: 5000 }, async () => {
  await withFixture(async ({ base, report, recheck, requests }) => {
    const result = await recheck(report(503, '/healthy') + report(404, '/gone') +
      report(403, '/denied') + report(501, '/unsupported') +
      '* [ERROR] <file:///missing.md> | File not found\n' +
      `* [200] <${base}/fragment#missing> | Failed to resolve fragment\n` +
      report(503, '/temporary#missing'));
    assert.equal(result.output, '');
    assert.equal(result.recovered, `${base}/healthy\n`);
    assert.deepEqual(requests, ['/healthy', '/healthy']);
  });
});

test('a persistent 503 exhausts the budget and never sets all_recovered', { timeout: 5000 }, async () => {
  await withFixture(async ({ report, recheck, requests }) => {
    const result = await recheck(report(503, '/persistent'), '0.5');
    assert.equal(result.output, '');
    assert.equal(result.recovered, '');
    assert.ok(requests.length > 0 && requests.length < 10);
    assert.match(result.stdout, /Still broken:.*503/);
  });
});

test('a temporary error followed by a 404 stops retrying and stays failed', { timeout: 5000 }, async () => {
  await withFixture(async ({ report, recheck, requests }) => {
    const result = await recheck(report(503, '/becomes-gone'));
    assert.equal(result.output, '');
    assert.equal(result.recovered, '');
    assert.deepEqual(requests, ['/becomes-gone', '/becomes-gone']);
    assert.match(result.stdout, /Still broken:.*404/);
  });
});

test('the same temporary failure cited in two files counts as one recovered URL', { timeout: 5000 }, async () => {
  await withFixture(async ({ report, recheck }) => {
    const result = await recheck(report(503, '/duplicate').repeat(2));
    assert.equal(result.output, 'all_recovered=true\n');
  });
});

test('one slow request cannot exceed the budget or start requests after it', { timeout: 5000 }, async () => {
  let calls = 0;
  const started = Date.now();
  const result = await recheckFailures(['https://example.com/a', 'https://example.com/b'], {
    accept: '200..=299', userAgent: 'lychee', budgetSeconds: 0.03, initialWaitMs: 5,
    fetchImpl: async (_url, { signal }) => {
      calls += 1;
      return new Promise((_, reject) => {
        // Bound the fixture independently of the production abort timer so
        // running against the old implementation cannot hold the test open.
        const timer = setTimeout(() => reject(new Error('fixture expired')), 50);
        signal.addEventListener('abort', () => {
          clearTimeout(timer);
          reject(new Error('aborted'));
        }, { once: true });
      });
    },
  });
  assert.equal(calls, 1);
  assert.equal(result.stillBroken.length, 2);
  assert.ok(Date.now() - started < 500);
});
JS
