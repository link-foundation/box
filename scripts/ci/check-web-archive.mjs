#!/usr/bin/env node

/**
 * check-web-archive.mjs
 *
 * Reads lychee's markdown report, and for every broken URL asks the Wayback
 * Machine whether a snapshot exists. A broken link with a snapshot is reported
 * as a `::notice` carrying the replacement URL; a broken link without one is a
 * `::error`, because nothing can be done with it except fixing or removing it.
 *
 * Why this exists (issue #115, R3/R5): ported from the template's
 * scripts/check-web-archive.mjs, kept close to the original so fixes flow both
 * ways. The one behaviour that matters here is the one the template already
 * had: the script never rewrites a link and never silences one. It tells the
 * author which of the two possible fixes is available. Silencing belongs in
 * .lycheeignore, and only for a URL that is correct but unverifiable.
 *
 * The Wayback Availability API is documented at
 * https://archive.org/help/wayback_api.php - a single GET, no key, so a
 * documentation gate does not acquire a credential to run.
 *
 * Usage:
 *   node scripts/ci/check-web-archive.mjs
 *
 * Environment variables:
 *   LYCHEE_OUTPUT   Path to lychee's markdown output (default: lychee/out.md)
 *   RECOVERED_URLS  Path to the list of URLs the re-check
 *                   (scripts/ci/recheck-broken-links.mjs) found healthy after
 *                   lychee got no answer or a temporary HTTP error, one per line
 *                   (default: lychee/recovered.txt). Those URLs are skipped;
 *                   a missing file skips nothing.
 *   GITHUB_OUTPUT   Set by GitHub Actions; receives `all_archived`
 *
 * Exit codes:
 *   0  no broken links, or every broken link has an archived version
 *   1  at least one broken link has no archived version, or lychee reported a
 *      failure with no http(s) URL to look up (a missing local file, an
 *      unresolvable relative link)
 */

import { readFileSync, appendFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const WAYBACK_API = 'https://archive.org/wayback/available?url=';

/**
 * Write an output for later workflow steps, and echo it so a local run shows
 * the same value CI would act on.
 * @param {string} name - Output name
 * @param {string} value - Output value
 */
function setOutput(name, value) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile) {
    appendFileSync(outputFile, `${name}=${value}\n`);
  }
  console.log(`${name}=${value}`);
}

/** Extract only failure sections, excluding successful redirects and summaries.
 * Legacy reports without per-input headings are parsed in full.
 */
export function extractErrorsSection(content) {
  const lines = content.split('\n');
  const sections = [];
  let depth = 0;
  let hasSections = false;
  for (const line of lines) {
    const heading = /^(#+)\s+(.+?)\s*$/.exec(line);
    if (heading && /per input$/.test(heading[2])) hasSections = true;
    if (heading && depth && heading[1].length <= depth) depth = 0;
    if (heading && /^(Errors|Timeouts) per input$/.test(heading[2])) {
      depth = heading[1].length;
    } else if (depth) {
      sections.push(line);
    }
  }
  return hasSections ? sections.join('\n') : content;
}

/** Read the same failure entries for recovery and archive suggestions. */
export function readFailureEntries(content) {
  const section = extractErrorsSection(content);
  const pattern = /^[ \t]*[*-][ \t]+\[([^\]\r\n]+)\][ \t]+(?:<([^>\r\n]+)>|([^\s<>|]+))(?:[ \t]+\(at [^)\r\n]*\))?[ \t]*(?:\|[ \t]*)?([^\r\n]*)$/gim;
  return Array.from(section.matchAll(pattern), ([, marker, bracketed, bare, detail]) => ({
    marker: marker.trim(),
    url: bracketed ?? bare,
    detail: detail.trim(),
  }));
}

/** Require the reported failure total before issuing a recovery verdict. */
export function validateFailureReport(report, exitCode) {
  const failures = readFailureEntries(report);
  const rows = extractErrorsSection(report).match(/^[ \t]*[*-][ \t]+\[/gm) ?? [];
  const counts = new Map(
    Array.from(report.matchAll(/^\|[^|\r\n]*\b(Errors|Timeouts|Unknown)[ \t]*\|[ \t]*(\d+)[ \t]*\|/gm),
      ([, name, count]) => [name, Number(count)])
  );
  const total = (counts.get('Errors') ?? 0) + (counts.get('Timeouts') ?? 0);
  if ((exitCode !== undefined && exitCode !== '2') ||
      rows.length !== failures.length ||
      (counts.size > 0 && total !== failures.length) ||
      (counts.get('Unknown') ?? 0) > 0 ||
      (exitCode === '2' &&
        (!counts.has('Errors') || !counts.has('Timeouts') || total === 0 ||
          !/^# Summary[ \t]*\r?$/m.test(report)))) {
    throw new Error('The checker exit status or report is incomplete.');
  }
}

export function extractBrokenLinks(content) {
  const urls = new Set();
  const others = new Set();
  for (const { url } of readFailureEntries(content)) {
    (/^https?:\/\//i.test(url) ? urls : others).add(url);
  }
  return { urls: [...urls], others: [...others] };
}

/**
 * Extract broken http(s) URLs from lychee markdown output.
 * @param {string} content - The markdown content from lychee
 * @returns {string[]} Array of broken URLs
 */
export function extractBrokenUrls(content) {
  return extractBrokenLinks(content).urls;
}

/**
 * Drop the URLs the re-check found healthy.
 *
 * A URL that never answered lychee but answers the re-check is not a broken
 * link (issue #121, lycheeverse/lychee#2297). Leaving it in this report would
 * send a healthy URL to the Wayback Machine and fail the job on whatever came
 * back - a false positive laundered through a second service.
 *
 * @param {string[]} urls - Broken http(s) URLs from the lychee report
 * @param {string} recoveredText - The re-check's output file, one URL per line
 * @returns {{remaining: string[], recovered: string[]}}
 */
export function splitRecoveredUrls(urls, recoveredText) {
  const recoveredSet = new Set(
    (recoveredText || '')
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)
  );

  return {
    remaining: urls.filter((url) => !recoveredSet.has(url)),
    recovered: urls.filter((url) => recoveredSet.has(url)),
  };
}

/**
 * Ask the Wayback Machine whether a URL has an archived snapshot.
 * @param {string} url - The URL to check
 * @returns {Promise<{available: boolean, archiveUrl?: string, timestamp?: string, error?: string}>}
 */
export async function checkWaybackMachine(url, { fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const apiUrl = `${WAYBACK_API}${encodeURIComponent(url)}`;

  const controller = new AbortController();
  const timeoutId = globalThis.setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetchImpl(apiUrl, {
      headers: {
        'User-Agent': 'box-link-checker/1.0 (GitHub Actions CI)',
      },
      signal: controller.signal,
    });

    if (!response.ok) {
      return { available: false, error: 'HTTP ' + response.status };
    }

    const data = await response.json();
    const snapshots = data?.archived_snapshots;
    if (!snapshots || typeof snapshots !== 'object' || Array.isArray(snapshots)) {
      return { available: false, error: 'invalid snapshot response' };
    }
    const snapshot = snapshots.closest;
    if (snapshot?.available === true) {
      const archiveUrl = new URL(snapshot.url);
      if (!['http:', 'https:'].includes(archiveUrl.protocol) ||
          typeof snapshot.timestamp !== 'string') {
        return { available: false, error: 'invalid snapshot URL or timestamp' };
      }
      archiveUrl.protocol = 'https:';
      return { available: true, archiveUrl: archiveUrl.href, timestamp: snapshot.timestamp };
    }
    if (Object.keys(snapshots).length === 0 || snapshot?.available === false) {
      return { available: false };
    }
    return { available: false, error: 'invalid snapshot response' };
  } catch (error) {
    return { available: false, error: error.message };
  } finally {
    globalThis.clearTimeout(timeoutId);
  }
}

/**
 * Render a Wayback Machine timestamp (YYYYMMDDHHmmss) as a readable date
 * @param {string} timestamp - e.g. "20231015143022"
 * @returns {string} Date formatted as YYYY-MM-DD
 */
export function formatTimestamp(timestamp) {
  if (!timestamp || timestamp.length < 8) {
    return timestamp;
  }
  const year = timestamp.slice(0, 4);
  const month = timestamp.slice(4, 6);
  const day = timestamp.slice(6, 8);
  return `${year}-${month}-${day}`;
}

/**
 * Report lychee errors that have no http(s) URL to look up in the Wayback
 * Machine. Local files and unresolvable root-relative links have no archived
 * equivalent, so they can never be `all_archived` and always fail the check.
 * @param {string[]} unarchivableLinks - Broken links that are not http(s) URLs
 */
function reportUnarchivableLinks(unarchivableLinks) {
  if (unarchivableLinks.length === 0) {
    return;
  }

  console.log(
    `✗ ${unarchivableLinks.length} broken link(s) cannot be checked against the Web Archive:`
  );
  for (const link of unarchivableLinks) {
    console.log(`  ${link}`);
    console.log(
      '::error title=Broken link - not recoverable from the Web Archive::' +
        `Broken link detected: ${link}\n` +
        'It is not an http(s) URL (missing file, unresolvable relative link, ...),\n' +
        'so the Wayback Machine cannot provide a fallback.\n' +
        'How to fix: correct the path, restore the missing file, or pass --root-dir\n' +
        'to lychee so root-relative links resolve.'
    );
  }
  console.log('');
}

/**
 * Report broken links that have a Wayback Machine snapshot as suggestions
 * @param {Array<{url: string, archiveUrl: string, date: string}>} withArchive - Archived links
 */
function reportArchivedLinks(withArchive) {
  if (withArchive.length === 0) {
    return;
  }

  console.log(
    `✓ ${withArchive.length} broken link(s) have Web Archive versions - consider replacing:`
  );
  for (const { url, archiveUrl, date } of withArchive) {
    console.log(`  Original: ${url}`);
    console.log(`  Archive (${date}): ${archiveUrl}`);
    console.log('');
  }

  for (const { url, archiveUrl, date } of withArchive) {
    console.log(
      `::notice title=Broken link - Web Archive available (${date})::` +
        `Broken link detected: ${url}\n` +
        `A Web Archive snapshot from ${date} is available.\n` +
        `Suggested fix: replace the broken link with the archived version:\n` +
        `  ${archiveUrl}`
    );
  }
}

/**
 * Report broken links that have no Wayback Machine snapshot as errors
 * @param {string[]} withoutArchive - Broken URLs with no archived version
 */
function reportUnarchivedUrls(withoutArchive) {
  if (withoutArchive.length === 0) {
    return;
  }

  console.log(
    `✗ ${withoutArchive.length} broken link(s) have NO Web Archive version:`
  );
  for (const url of withoutArchive) {
    console.log(`  ${url}`);
  }
  console.log('');

  for (const url of withoutArchive) {
    console.log(
      `::error title=Broken link - No Web Archive fallback::` +
        `Broken link detected: ${url}\n` +
        `No archived version was found in the Wayback Machine.\n` +
        `How to fix:\n` +
        `  1. Find an updated URL for the same or equivalent content and replace the link.\n` +
        `  2. Replace it with prose naming what it used to point at, when the content is gone for good.\n` +
        `  3. Add it to .lycheeignore ONLY if the URL is correct and merely unverifiable\n` +
        `     (login-gated, rate-limited, bot-blocked). A dead link is not a false positive.`
    );
  }
}

/**
 * Main function
 */
async function main() {
  const lycheeOutput = process.env.LYCHEE_OUTPUT || 'lychee/out.md';

  console.log('=== Web Archive Fallback Check ===\n');
  console.log(`Reading lychee output from: ${lycheeOutput}\n`);

  const exitCode = process.env.LYCHEE_EXIT_CODE;
  if (exitCode === undefined && !existsSync(lycheeOutput)) {
    console.log('No lychee output file found. Skipping web archive check.');
    setOutput('all_archived', 'true');
    process.exit(0);
  }

  const content = readFileSync(lycheeOutput, 'utf-8');
  validateFailureReport(content, exitCode);
  const { urls: reportedUrls, others: unarchivableLinks } =
    extractBrokenLinks(content);

  const recoveredFile = process.env.RECOVERED_URLS || 'lychee/recovered.txt';
  const recoveredText = existsSync(recoveredFile)
    ? readFileSync(recoveredFile, 'utf-8')
    : '';
  const { remaining: brokenUrls, recovered: recheckedHealthy } =
    splitRecoveredUrls(reportedUrls, recoveredText);

  for (const url of recheckedHealthy) {
    console.log(
      `\u2713 ${url} never answered lychee but answers the re-check - not broken`
    );
  }

  reportUnarchivableLinks(unarchivableLinks);

  if (brokenUrls.length === 0) {
    console.log('No broken URLs found in lychee output.');
    const clean = unarchivableLinks.length === 0;
    setOutput('all_archived', clean ? 'true' : 'false');
    process.exit(clean ? 0 : 1);
  }

  console.log(
    `Found ${brokenUrls.length} broken URL(s). Checking Web Archive...\n`
  );

  const withArchive = [];
  const withoutArchive = [];
  let failedLookups = 0;
  const deadline = Date.now() + 30_000;

  for (const url of brokenUrls) {
    console.log(`Checking: ${url}`);
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      console.log('Web Archive lookup budget expired. Remaining snapshots could not be checked.');
      failedLookups += 1;
      break;
    }
    const result = await checkWaybackMachine(url, { timeoutMs: Math.min(10_000, remaining) });

    if (result.available) {
      const date = formatTimestamp(result.timestamp);
      console.log(`  ✓ Archived on ${date}: ${result.archiveUrl}`);
      withArchive.push({ url, archiveUrl: result.archiveUrl, date });
    } else if (result.error) {
      console.log('  Web Archive lookup failed for %s (%s). Snapshot availability is unknown.', url, result.error);
      failedLookups += 1;
    } else {
      console.log('  ✗ Not found in Web Archive');
      withoutArchive.push(url);
    }

    // Small delay to avoid rate-limiting the Wayback API
    const waitMs = Math.min(500, deadline - Date.now());
    if (waitMs > 0 && url !== brokenUrls.at(-1)) {
      await new Promise((resolve) => globalThis.setTimeout(resolve, waitMs));
    }
  }

  console.log('\n=== Web Archive Check Summary ===\n');

  reportArchivedLinks(withArchive);
  reportUnarchivedUrls(withoutArchive);

  const allArchived =
    withoutArchive.length === 0 && unarchivableLinks.length === 0 &&
    failedLookups === 0;
  setOutput('all_archived', allArchived ? 'true' : 'false');

  if (!allArchived) {
    console.log(
      '\nAction required: fix or remove the broken links listed above.'
    );
    process.exit(1);
  }

  console.log(
    '\nEvery broken link has a Web Archive snapshot; replace them with the archive.org URLs above.'
  );
  process.exit(0);
}

const isDirectExecution =
  process.argv[1] &&
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);

if (isDirectExecution) {
  main().catch((error) => {
    console.error('Unexpected error:', error);
    process.exit(1);
  });
}
