#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { checkWaybackMachine, extractBrokenLinks } from './scripts/ci/check-web-archive.mjs';
import { parseLycheeFailures, recheckFailures } from './scripts/ci/recheck-broken-links.mjs';

const url = 'https://example.org/path(part)?';
const report = [
  '| 🚫 Errors | 1 |',
  '| ⏳ Timeouts | 1 |',
  '## Errors per input',
  '* [404] <https://example.org/gone> (at 8:5) | Rejected status code: 404',
  '## Timeouts per input',
  '* [TIMEOUT] <' + url + '> (at 11:5) | Request timed out',
  '## Redirects per input',
  '* [301] <https://example.org/moved> → <https://example.org/new>',
].join('\n');

test('both consumers read errors and timeouts and ignore redirects', () => {
  assert.deepEqual(extractBrokenLinks(report).urls, ['https://example.org/gone', url]);
  assert.deepEqual(parseLycheeFailures(report).map((entry) => entry.url), [
    'https://example.org/gone', url,
  ]);
});

test('a runtime failure or incomplete report cannot be recovered', () => {
  const dir = mkdtempSync(join(tmpdir(), 'box-link-verdict-'));
  const output = join(dir, 'github-output');
  const reportFile = join(dir, 'report.md');
  const recovered = join(dir, 'recovered.txt');
  const temporary = [
    '| Errors | 0 |',
    '| Timeouts | 1 |',
    '## Timeouts per input',
    '* [TIMEOUT] <https://example.org/page> | timed out',
  ].join('\n');
  try {
    for (const [code, content] of [
      ['1', temporary],
      ['2', temporary.replace('| Errors | 0 |', '| Errors | 1 |')],
      ['2', temporary + '\n* [404] <broken'],
    ]) {
      writeFileSync(output, '');
      writeFileSync(reportFile, content);
      const run = spawnSync(process.execPath, ['scripts/ci/recheck-broken-links.mjs'], {
        env: { ...process.env, LYCHEE_EXIT_CODE: code, LYCHEE_OUTPUT: reportFile,
          GITHUB_OUTPUT: output, RECOVERED_OUTPUT: recovered, RECHECK_BUDGET_SECONDS: '0' },
        encoding: 'utf8',
      });
      assert.equal(run.status, 0, run.stderr);
      assert.match(run.stderr, /checker exit status or report is incomplete/);
      assert.equal(readFileSync(output, 'utf8'), '');
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('link recovery tests the same GET method as the checker', async () => {
  const result = await recheckFailures([url], {
    accept: '200..=299', userAgent: 'lychee', budgetSeconds: 1,
    fetchImpl: async (_, request) => new Response(null, {
      status: request.method === 'HEAD' ? 200 : 404,
    }),
  });
  assert.deepEqual(result.recovered, []);
  assert.equal(result.stillBroken[0].status, 404);
});

test('an archive outage or invalid payload is distinct from a successful empty lookup', async () => {
  const lookup = (response) => checkWaybackMachine(url, { fetchImpl: async () => response });
  assert.deepEqual(await lookup(new Response(null, { status: 503 })), {
    available: false, error: 'HTTP 503',
  });
  assert.deepEqual(await lookup(Response.json({})), {
    available: false, error: 'invalid snapshot response',
  });
  assert.deepEqual(await lookup(Response.json({ archived_snapshots: {} })), { available: false });
  assert.deepEqual(await lookup(Response.json({
    archived_snapshots: { closest: { available: true, timestamp: '20201011040051',
      url: 'http://web.archive.org/web/20201011040051/https://example.org' } },
  })), { available: true, timestamp: '20201011040051',
    archiveUrl: 'https://web.archive.org/web/20201011040051/https://example.org' });
});
JS
