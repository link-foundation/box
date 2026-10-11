#!/usr/bin/env node

/**
 * recheck-broken-links.mjs
 *
 * Re-ask unanswered lychee failures and temporary HTTP errors.
 *
 * Why this exists (issue #121; ported from the reference template's
 * scripts/recheck-broken-links.mjs). lychee's `--max-retries` classifies an
 * error by the phase it happened in, and a failure during connect is answered
 * `false` - it is never retried (lycheeverse/lychee#2297). A healthy URL that
 * answers one TCP reset, which is a normal event for a rate-limiting or
 * load-shedding host seen from a CI address range, is therefore reported
 * broken without a single retry, and this repository's links gate fails on it.
 * That is a false positive of exactly the kind issue #121 is about, and the
 * two hosts .lycheeignore already silences for availability rather than
 * correctness (manpages.ubuntu.com, www.gnu.org) show how the alternative fix
 * degrades: a real 404 on those hosts would now be silent forever.
 *
 * PR #132 also failed on two healthy GitHub documentation links answering 503.
 * A temporary server error is not a verdict on whether the document exists:
 * retry 408, 429, 500, 502, 503 and 504 within the same bounded budget. Only an
 * accepted response recovers a URL; a persistent error still fails the gate.
 * Other HTTP failures, including 404, remain final. Fragment URLs also remain
 * final because a HEAD request cannot validate an anchor.
 *
 * Divergence from the template, deliberate
 * ----------------------------------------
 * The template writes `all_recovered=true` whenever every *unanswered* failure
 * recovered, without looking at the answered ones - and its links.yml gates
 * both the Web Archive step and the "Fail if broken links were found" step on
 * `all_recovered != 'true'`. So a report holding one 404 and one connection
 * reset ends green with the 404 in it. Reproduced against the template's own
 * script by experiments/issue-121-template-recheck/, reported upstream as
 * link-foundation/js-ai-driven-development-pipeline-template#184 and
 * link-foundation/rust-ai-driven-development-pipeline-template#170, and
 * not copied: here `all_recovered` means "the whole report was noise", so it
 * is written only when every failure was eligible for retry and all of them
 * recovered.
 *
 * Usage:
 *   node scripts/ci/recheck-broken-links.mjs
 *
 * Environment variables:
 *   LYCHEE_OUTPUT            lychee's markdown report (default: lychee/out.md)
 *   RECOVERED_OUTPUT         where to write the recovered URLs, one per line
 *                            (default: lychee/recovered.txt)
 *   LINKS_WORKFLOW           workflow to read lychee's request options from
 *                            (default: .github/workflows/links.yml)
 *   RECHECK_BUDGET_SECONDS   wall-clock budget for the whole re-check
 *                            (default: 240; expires before the job's 10-minute cap)
 *   RECHECK_WAIT_MS          first wait between rounds, doubling (default: 2000)
 *   BOX_VERBOSE             set to 1 to trace each request (default: off)
 *   GITHUB_OUTPUT            set by GitHub Actions; receives `all_recovered`
 *
 * GitHub Actions outputs:
 *   all_recovered  'true' only when the report held nothing but retryable
 *                  failures, and every URL returns an accepted status now.
 *                  Consumers must test `!= 'true'`, never `== 'false'`: a
 *                  skipped or crashed step leaves the output empty, and only
 *                  the `!=` form fails safe.
 *
 * Exit codes:
 *   0 in every case. This script only ever downgrades a failure, so a bug in
 *   it must not be able to turn a green run red - or a red one green by
 *   crashing before the gate reads its output.
 */

import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// Read from process.env inside main() only: the assertions in
// experiments/test-issue121-links-recheck.sh import this module, and
// module-scope environment access would run before they can set it.
const BUDGET_SECONDS_DEFAULT = 240;
const INITIAL_WAIT_MS_DEFAULT = 2000;
const REQUEST_TIMEOUT_MS = 30_000;
const USER_AGENT_DEFAULT = 'lychee';
// lychee's documented default --accept list, used when the workflow sets no
// --accept flag. The workflow is parsed rather than duplicated so the re-check
// cannot start judging URLs by a rule the checker no longer uses.
const ACCEPT_DEFAULT = '100..=103,200..=299';
const RETRYABLE_HTTP_STATUSES = new Set([408, 429, 500, 502, 503, 504]);

/**
 * Split a lychee markdown report into per-failure records.
 *
 * A failure is "answered" when the marker is a status code ([404]) or the
 * detail says "Rejected status code": a host replied.
 * Everything else - [ERROR], [TIMEOUT], [UNKNOWN] - is a failure where no host
 * ever answered.
 *
 * @param {string} content - lychee's markdown report
 * @returns {Array<{marker: string, url: string, detail: string, answered: boolean, status: number|null}>}
 */
export function parseLycheeFailures(content) {
  const failures = [];
  const entryPattern =
    /^\s*(?:\*|-)\s+\[([^\]]+)\]\s+<?([^\s>|)]+)>?(?:\s+\(at [^)]*\))?\s*\|?\s*(.*)$/gim;

  let match;
  while ((match = entryPattern.exec(content)) !== null) {
    const marker = match[1].trim();
    const url = match[2].trim().replace(/[.,;!?]+$/, '');
    const detail = match[3].trim();

    if (!url) {
      continue;
    }

    const answered =
      /^\d{3}$/.test(marker) || /rejected status code/i.test(detail);
    const statusMatch = /^\d{3}$/.test(marker)
      ? marker
      : detail.match(/rejected status code:\s*(\d{3})\b/i)?.[1];
    const status = statusMatch ? Number(statusMatch) : null;

    failures.push({ marker, url, detail, answered, status });
  }

  return failures;
}

/**
 * Build an "is this status accepted" predicate from a lychee --accept list
 * such as "100..=103,200..=299,429" (spaces tolerated).
 * @param {string} spec - lychee's --accept list
 * @returns {(status: number) => boolean}
 */
export function parseAcceptRanges(spec) {
  const accepted = new Set();

  for (const part of spec.split(',')) {
    const trimmed = part.trim();

    if (!trimmed) {
      continue;
    }

    const range = trimmed.match(/^(\d+)\.\.=(\d+)$/);

    if (range) {
      for (
        let status = Number(range[1]);
        status <= Number(range[2]);
        status += 1
      ) {
        accepted.add(status);
      }
      continue;
    }

    if (/^\d{3}$/.test(trimmed)) {
      accepted.add(Number(trimmed));
    }
  }

  return (status) => accepted.has(status);
}

/**
 * Read the --accept list and --user-agent the lychee step runs with, so the
 * re-check judges a URL by the rules the checker used.
 * @param {string} workflowText - the links workflow
 * @returns {{accept: string, userAgent: string}}
 */
export function extractLycheeRequestOptions(workflowText) {
  const accept = workflowText.match(/--accept[=\s]+["']?([^\s"']+)["']?/);
  const userAgent = workflowText.match(
    /--user-agent[=\s]+["']?([^\s"']+)["']?/
  );

  return {
    accept: accept ? accept[1] : ACCEPT_DEFAULT,
    userAgent: userAgent ? userAgent[1] : USER_AGENT_DEFAULT,
  };
}

/**
 * Decide whether the run may be called clean.
 *
 * `all_recovered` is read by the workflow as "there is nothing left to fail
 * on", so it has to account for the whole report, not just the part this
 * script re-asked. A final HTTP failure (a 404, a broken fragment) and a
 * failure with no URL to ask (a missing local file) are both still there after
 * a perfect re-check, and neither is this script's to forgive.
 *
 * @param {{finalFailureCount: number, retryableCount: number, recoveredCount: number, stillBrokenCount: number}} counts
 * @returns {boolean}
 */
export function allRecovered(counts) {
  return (
    counts.finalFailureCount === 0 &&
    counts.stillBrokenCount === 0 &&
    counts.retryableCount > 0 &&
    counts.recoveredCount === counts.retryableCount
  );
}

/**
 * Ask every URL again, round by round with a doubling wait, until each one
 * returns an accepted or permanent status, or the budget runs out. Temporary
 * HTTP errors stay pending, just like a URL that keeps refusing to answer.
 *
 * @param {string[]} urls - the URLs eligible for retry
 * @param {{accept: string, userAgent: string, budgetSeconds?: number, initialWaitMs?: number, verbose?: boolean, fetchImpl?: typeof fetch}} options
 * @returns {Promise<{recovered: string[], stillBroken: Array<{url: string, status: number|null, reason: string}>}>}
 */
export async function recheckFailures(urls, options) {
  const accept = parseAcceptRanges(options.accept);
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const budgetMs = (options.budgetSeconds ?? BUDGET_SECONDS_DEFAULT) * 1000;
  const startedAt = Date.now();
  const initialWaitMs = options.initialWaitMs ?? INITIAL_WAIT_MS_DEFAULT;
  let waitMs = initialWaitMs;
  let round = 0;

  const recovered = [];
  const rejected = [];
  const lastStatus = new Map();
  let pending = [...new Set(urls)];

  while (pending.length > 0 && Date.now() - startedAt < budgetMs) {
    if (round > 0) {
      const elapsed = Date.now() - startedAt;

      // Never start a wait the budget cannot pay for: the point of the budget
      // is that this script finishes well inside the job's cap.
      if (elapsed + waitMs > budgetMs) {
        break;
      }

      await new Promise((resolve) => setTimeout(resolve, waitMs));
      waitMs *= 2;
    }
    round += 1;

    const stillPending = [];

    for (const [index, url] of pending.entries()) {
      const remainingMs = budgetMs - (Date.now() - startedAt);
      if (remainingMs <= 0) {
        stillPending.push(...pending.slice(index));
        break;
      }
      const controller = new AbortController();
      const timeoutId = setTimeout(
        () => controller.abort(),
        Math.min(REQUEST_TIMEOUT_MS, remainingMs)
      );
      let response;

      try {
        response = await fetchImpl(url, {
          method: 'HEAD',
          redirect: 'follow',
          signal: controller.signal,
          headers: { 'user-agent': options.userAgent },
        });
      } catch {
        // Still no answer this round; it stays eligible for the next one.
        if (options.verbose) {
          console.log(`Re-check round ${round}: ${url} did not answer`);
        }
        stillPending.push(url);
        continue;
      } finally {
        clearTimeout(timeoutId);
      }

      lastStatus.set(url, response.status);
      if (options.verbose) {
        console.log(`Re-check round ${round}: ${url} answered ${response.status}`);
      }
      if (accept(response.status)) {
        recovered.push(url);
      } else if (RETRYABLE_HTTP_STATUSES.has(response.status)) {
        stillPending.push(url);
      } else {
        rejected.push({
          url,
          status: response.status,
          reason: `answered ${response.status}, which lychee does not accept`,
        });
      }
    }

    pending = stillPending;
  }

  return {
    recovered,
    stillBroken: [
      ...rejected,
      ...pending.map((url) => ({
        url,
        status: lastStatus.get(url) ?? null,
        reason: lastStatus.has(url)
          ? `HTTP ${lastStatus.get(url)} did not recover within the re-check budget`
          : 'no answer within the re-check budget',
      })),
    ],
  };
}

async function main() {
  const lycheeOutput = process.env.LYCHEE_OUTPUT || 'lychee/out.md';
  const recoveredOutput =
    process.env.RECOVERED_OUTPUT || 'lychee/recovered.txt';
  const workflow =
    process.env.LINKS_WORKFLOW || '.github/workflows/links.yml';
  const options = extractLycheeRequestOptions(readFileSync(workflow, 'utf8'));
  const failures = parseLycheeFailures(readFileSync(lycheeOutput, 'utf8'));

  const canRetry = (failure) =>
    /^https?:\/\//i.test(failure.url) &&
    !new URL(failure.url).hash &&
    (!failure.answered || RETRYABLE_HTTP_STATUSES.has(failure.status));
  // Local files, anchors and permanent HTTP errors cannot be verified by
  // this recovery pass. They stay final even if every other URL recovers.
  const finalFailures = failures.filter((failure) => !canRetry(failure));
  const retryable = [
    ...new Set(failures.filter(canRetry).map((failure) => failure.url)),
  ];

  console.log(
    `Re-check: ${failures.length} lychee failure(s); ` +
      `${finalFailures.length} final, ` +
      `${retryable.length} eligible for retry`
  );

  if (retryable.length === 0) {
    console.log('Re-check: nothing to re-ask.');
    return;
  }

  const result = await recheckFailures(retryable, {
    ...options,
    budgetSeconds: Number(
      process.env.RECHECK_BUDGET_SECONDS || BUDGET_SECONDS_DEFAULT
    ),
    initialWaitMs: Number(
      process.env.RECHECK_WAIT_MS || INITIAL_WAIT_MS_DEFAULT
    ),
    verbose: process.env.BOX_VERBOSE === '1',
  });

  for (const url of result.recovered) {
    console.log(
      `::notice title=Link recovered on re-check::${url} failed temporarily in lychee ` +
        `but answers ${options.accept} now - not a broken link`
    );
  }

  if (result.recovered.length > 0) {
    writeFileSync(recoveredOutput, `${result.recovered.join('\n')}\n`);
  }

  for (const { url, reason } of result.stillBroken) {
    console.log(`Still broken: ${url} - ${reason}`);
  }

  console.log(
    `Re-check finished: ${result.recovered.length} recovered, ` +
      `${result.stillBroken.length} still broken`
  );

  const clean = allRecovered({
    finalFailureCount: finalFailures.length,
    retryableCount: retryable.length,
    recoveredCount: result.recovered.length,
    stillBrokenCount: result.stillBroken.length,
  });

  if (clean) {
    appendFileSync(
      process.env.GITHUB_OUTPUT || '/dev/null',
      'all_recovered=true\n'
    );
    console.log(
      'all_recovered=true: every failure in the report was retryable, ' +
        'and all URLs return an accepted status now.'
    );
    return;
  }

  if (finalFailures.length > 0 && result.stillBroken.length === 0) {
    console.log(
      `all_recovered stays unset: ${finalFailures.length} final failure(s) ` +
        'are still in the report.'
    );
  }
}

// The re-check only downgrades failures, so a crash here must not be able to
// masquerade as a verdict in either direction: exit 0, leave all_recovered
// unset, and let the gate fail on lychee's own result.
const isDirectExecution =
  process.argv[1] &&
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);

if (isDirectExecution) {
  main().catch((error) => {
    console.error(`Re-check crashed (treating as no recovery): ${error}`);
    process.exit(0);
  });
}
