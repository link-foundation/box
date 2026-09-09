import { spawn } from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'test-anywhere';
import {
  extractLycheeRequestOptions,
  parseAcceptRanges,
  parseLycheeFailures,
  recheckUnanswered,
} from '../scripts/recheck-broken-links.mjs';
import { splitRecoveredUrls } from '../scripts/check-web-archive.mjs';

const fixtureReport = readFileSync('tests/fixtures/lychee-report.md', 'utf8');
const linksWorkflow = readFileSync('.github/workflows/links.yml', 'utf8');

function once(fn) {
  let called = false;
  return (...args) => {
    if (called) {
      throw new Error('fetch called twice');
    }
    called = true;
    return fn(...args);
  };
}

describe('lychee report classification', () => {
  it('marks a failure carrying a status code as final', () => {
    const failures = parseLycheeFailures(fixtureReport);
    const answered = failures.filter((failure) => failure.answered);

    expect(answered.length).toBe(2);
    expect(answered.map((failure) => failure.url)).toEqual([
      'https://example.com/csharp/',
      'https://example.com/rust/link_cli/',
    ]);
    expect(answered[0].detail).toContain('Rejected status code');
  });

  it('marks ERROR, TIMEOUT, and UNKNOWN markers as never answered', () => {
    const report = [
      '- [ERROR] <https://example.com/reset> | Connection reset by peer',
      '- [TIMEOUT] <https://example.com/slow> | Timeout',
      '- [UNKNOWN] <https://example.com/dark> | Unknown error',
    ].join('\n');
    const failures = parseLycheeFailures(report);

    expect(failures.every((failure) => !failure.answered)).toBe(true);
    expect(failures.map((failure) => failure.marker)).toEqual([
      'ERROR',
      'TIMEOUT',
      'UNKNOWN',
    ]);
  });

  it('treats a rejected status code as an answer whatever the marker', () => {
    const report =
      '- [ERROR] <https://example.com/gone> | Rejected status code: 503 Service Unavailable';

    expect(parseLycheeFailures(report)[0].answered).toBe(true);
  });

  it('keeps non-http failures out of the re-check even when unanswered', () => {
    const failures = parseLycheeFailures(fixtureReport);
    const unanswerable = failures.filter(
      (failure) => !failure.answered && !/^https?:\/\//i.test(failure.url)
    );

    expect(unanswerable.map((failure) => failure.url).sort()).toEqual([
      'error:',
      'file:///home/runner/work/repo/repo/csharp/docs/api/Foundation.Data.Doublets.Cli.yml',
    ]);
  });
});

describe('lychee request option sharing', () => {
  // The re-check must judge a URL by the same rules lychee used. Neither
  // flag is set in links.yml today, so lychee's documented defaults apply on
  // both sides; if either side changes, this test fails until the other
  // follows.
  it('reads the same accept list and user agent as the lychee step', () => {
    const options = extractLycheeRequestOptions(linksWorkflow);

    expect(options.accept).toBe('100..=103,200..=299');
    expect(options.userAgent).toBe('lychee');
    expect(linksWorkflow).not.toContain('--accept');
    expect(linksWorkflow).not.toContain('--user-agent');
  });

  it('extracts the flags when the workflow sets them', () => {
    const workflow = [
      '        args: >-',
      '          --verbose',
      '          --accept 200..=299,429',
      '          --user-agent my-checker/2.0',
    ].join('\n');
    const options = extractLycheeRequestOptions(workflow);

    expect(options.accept).toBe('200..=299,429');
    expect(options.userAgent).toBe('my-checker/2.0');
  });
});

describe('accept list parsing', () => {
  it('honours ranges, singles, and stray spaces', () => {
    const accepted = parseAcceptRanges(' 100..=103 , 200..=299, 429 ');

    expect(accepted(100)).toBe(true);
    expect(accepted(103)).toBe(true);
    expect(accepted(200)).toBe(true);
    expect(accepted(299)).toBe(true);
    expect(accepted(429)).toBe(true);
    expect(accepted(104)).toBe(false);
    expect(accepted(404)).toBe(false);
  });
});

describe('re-check requests', () => {
  it('recovers a URL that answers accepted', async () => {
    const result = await recheckUnanswered(['https://a.example/x'], {
      accept: '200..=299',
      userAgent: 'lychee',
      fetchImpl: once(() => Promise.resolve({ status: 200 })),
    });

    expect(result.recovered).toEqual(['https://a.example/x']);
    expect(result.stillBroken).toEqual([]);
  });

  it('stops at the first rejected answer and never retries it', async () => {
    let calls = 0;
    const result = await recheckUnanswered(['https://a.example/x'], {
      accept: '200..=299',
      userAgent: 'lychee',
      budgetSeconds: 5,
      initialWaitMs: 1,
      fetchImpl: () => {
        calls += 1;
        return Promise.resolve({ status: 404 });
      },
    });

    expect(calls).toBe(1);
    expect(result.recovered).toEqual([]);
    expect(result.stillBroken).toEqual([
      {
        url: 'https://a.example/x',
        status: 404,
        reason: 'answered 404, which lychee does not accept',
      },
    ]);
  });

  it('retries a URL that never answers and takes a later success', async () => {
    let calls = 0;
    const result = await recheckUnanswered(['https://a.example/x'], {
      accept: '200..=299',
      userAgent: 'lychee',
      budgetSeconds: 30,
      initialWaitMs: 1,
      fetchImpl: () => {
        calls += 1;
        if (calls < 3) {
          return Promise.reject(new Error('ECONNRESET'));
        }
        return Promise.resolve({ status: 204 });
      },
    });

    expect(calls).toBe(3);
    expect(result.recovered).toEqual(['https://a.example/x']);
  });

  it('gives up without an answer once the budget expires', async () => {
    const result = await recheckUnanswered(['https://a.example/x'], {
      accept: '200..=299',
      userAgent: 'lychee',
      budgetSeconds: 0,
      fetchImpl: () => Promise.reject(new Error('ECONNRESET')),
    });

    expect(result.recovered).toEqual([]);
    expect(result.stillBroken[0].status).toBe(null);
    expect(result.stillBroken[0].reason).toContain('no answer');
  });

  it('asks a duplicated URL only once', async () => {
    let calls = 0;
    const result = await recheckUnanswered(
      ['https://a.example/x', 'https://a.example/x'],
      {
        accept: '200..=299',
        userAgent: 'lychee',
        fetchImpl: once(() => {
          calls += 1;
          return Promise.resolve({ status: 200 });
        }),
      }
    );

    expect(calls).toBe(1);
    expect(result.recovered).toEqual(['https://a.example/x']);
  });

  it('sends the request the way lychee was configured to', async () => {
    let seen;
    await recheckUnanswered(['https://a.example/x'], {
      accept: '200..=299',
      userAgent: 'my-checker/2.0',
      fetchImpl: (url, init) => {
        seen = { url, init };
        return Promise.resolve({ status: 200 });
      },
    });

    expect(seen.url).toBe('https://a.example/x');
    expect(seen.init.method).toBe('HEAD');
    expect(seen.init.headers['user-agent']).toBe('my-checker/2.0');
  });
});

describe('re-check step end to end', () => {
  // The end-to-end fixtures spawn node and write outside the sandbox,
  // which the Deno leg's `--allow-read`-only test run cannot do.
  if (typeof Deno !== 'undefined') {
    return;
  }

  function writeReport(dir, entries) {
    const reportPath = path.join(dir, 'out.md');
    writeFileSync(reportPath, `## Errors per input\n\n${entries.join('\n')}\n`);
    return reportPath;
  }

  function runRecheck(env) {
    return new Promise((resolve) => {
      const child = spawn('node', ['scripts/recheck-broken-links.mjs'], {
        cwd: process.cwd(),
        env: { ...process.env, ...env },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      let output = '';
      child.stdout.on('data', (chunk) => {
        output += chunk;
      });
      child.stderr.on('data', (chunk) => {
        output += chunk;
      });
      child.on('close', (code) => resolve({ code, output }));
    });
  }

  it('recovers only the URLs that answer healthy and never re-asks a 404', async () => {
    const requests = [];
    const server = createServer((request, response) => {
      requests.push(request.url);
      if (request.url === '/healthy') {
        response.writeHead(200);
      } else {
        response.writeHead(404);
      }
      response.end();
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address();
    const base = `http://127.0.0.1:${port}`;

    const dir = mkdtempSync(path.join(tmpdir(), 'recheck-'));
    try {
      const reportPath = writeReport(dir, [
        `- [ERROR] <${base}/healthy> | Connection reset by peer`,
        `- [ERROR] <${base}/dead> | Connection reset by peer`,
        '- [404] <https://example.com/final/> | Rejected status code: 404 Not Found',
      ]);
      const recoveredPath = path.join(dir, 'recovered.txt');
      const outputPath = path.join(dir, 'github-output.txt');

      const { code, output } = await runRecheck({
        LYCHEE_OUTPUT: reportPath,
        RECOVERED_OUTPUT: recoveredPath,
        GITHUB_OUTPUT: outputPath,
        RECHECK_WAIT_MS: '10',
        RECHECK_BUDGET_SECONDS: '30',
      });

      expect(code).toBe(0);
      expect(readFileSync(recoveredPath, 'utf8')).toBe(`${base}/healthy\n`);
      expect(requests.sort()).toEqual(['/dead', '/healthy']);
      // The 404 was already an answer; re-asking it would be wrong.
      expect(requests).not.toContain('/final');
      // One link stayed broken, so the gate must not be released.
      expect(existsSync(outputPath)).toBe(false);
      expect(output).toContain('still without an answer');
    } finally {
      server.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('releases the gate only when every unanswered link recovered', async () => {
    const server = createServer((request, response) => {
      response.writeHead(200);
      response.end();
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address();

    const dir = mkdtempSync(path.join(tmpdir(), 'recheck-'));
    try {
      const reportPath = writeReport(dir, [
        `- [TIMEOUT] <http://127.0.0.1:${port}/slow> | Timeout`,
      ]);
      const recoveredPath = path.join(dir, 'recovered.txt');
      const outputPath = path.join(dir, 'github-output.txt');

      const { code } = await runRecheck({
        LYCHEE_OUTPUT: reportPath,
        RECOVERED_OUTPUT: recoveredPath,
        GITHUB_OUTPUT: outputPath,
        RECHECK_WAIT_MS: '10',
        RECHECK_BUDGET_SECONDS: '30',
      });

      expect(code).toBe(0);
      expect(readFileSync(outputPath, 'utf8')).toContain('all_recovered=true');
    } finally {
      server.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('exits 0 even when the report is missing entirely', async () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'recheck-'));
    try {
      const { code, output } = await runRecheck({
        LYCHEE_OUTPUT: path.join(dir, 'missing.md'),
        RECOVERED_OUTPUT: path.join(dir, 'recovered.txt'),
      });

      expect(code).toBe(0);
      expect(output).toContain('treating as no recovery');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('web archive fallback honouring the re-check', () => {
  it('drops recovered URLs from the archive lookup', () => {
    const { remaining, recovered } = splitRecoveredUrls(
      ['https://a.example/x', 'https://b.example/y'],
      'https://b.example/y\n'
    );

    expect(remaining).toEqual(['https://a.example/x']);
    expect(recovered).toEqual(['https://b.example/y']);
  });

  it('skips nothing when the recovered file is missing or empty', () => {
    const urls = ['https://a.example/x'];
    const fromMissing = splitRecoveredUrls(urls, '');
    const fromNull = splitRecoveredUrls(urls, null);

    expect(fromMissing.remaining).toEqual(urls);
    expect(fromNull.remaining).toEqual(urls);
  });
});
