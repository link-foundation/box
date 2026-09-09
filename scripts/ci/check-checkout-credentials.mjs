#!/usr/bin/env node

/**
 * Fails when a checkout does not say what happens to the job's token.
 *
 * `actions/checkout` authenticates by writing an AUTHORIZATION header into the
 * repository's git configuration, and by default it leaves it there: every
 * later step in that job can read it back and push with it. Setting
 * `persist-credentials: false` makes checkout take it out again at the end of
 * its own step, which is visible in a job log as `Removing HTTP extra header`
 * before the first real step instead of during `Post job cleanup`.
 *
 * Thirty of this repository's fifty-five checkouts said nothing, so thirty
 * jobs kept it — including `js / build-js-amd64`, which held it for 427
 * seconds while a docker build ran with the workspace as its build context,
 * and `Measure Component Disk Space`, which held it for 886
 * (experiments/reproduce-issue121-checkout-credentials.sh measures both out of
 * the downloaded run logs). zizmor has the audit for exactly this —
 * `artipacked` — and reports it at severity Low, which is under the floor the
 * workflow gate runs at, so it was filtered out thirty times: a check that
 * could not fail, which is what issue #121 is about.
 *
 * The rule here is not "always drop it". It is that the setting must be a
 * decision, and the decision must match what the job does:
 *
 *   - a job that writes to the remote must keep the credential;
 *   - every other job must drop it;
 *   - saying nothing is neither, and is reported as such, because the default
 *     is the unsafe one and silence hides which of the two was meant.
 *
 * "Writes to the remote" is derived, not listed: the job's `run:` lines are
 * followed into the scripts they call, transitively, and a `git push` anywhere
 * in that closure makes the job a writer. So a job that starts pushing through
 * a new helper is classified correctly without anyone remembering to update a
 * list here.
 *
 * Reads are anonymous under `persist-credentials: false` and that is fine
 * because this repository is public; the same reasoning, and the same caveat,
 * is written out at the fetch in scripts/ci/simulate-fresh-merge.sh.
 *
 * Usage:
 *   node scripts/ci/check-checkout-credentials.mjs [--verbose] [workflow.yml]...
 *   node scripts/ci/check-checkout-credentials.mjs --list-inputs
 *
 * Exit codes:
 *   0 = every checkout states a setting, and it matches what its job does
 *   1 = at least one checkout is silent or contradicts its job
 *   2 = the check could not run (unreadable file, bad usage, not a repository)
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { relative, resolve } from 'node:path';

const TITLE = 'check-checkout-credentials';

// A push through any of these reaches the remote with whatever credential the
// checkout left behind. `git push` covers the direct calls; the helper is
// named separately because the scripts that use it never spell the command.
const REMOTE_WRITE = [/\bgit\s+push\b/, /git-push-with-retry\.sh/];

function annotate(file, line, message) {
  const where = line ? `file=${file},line=${line}` : `file=${file}`;
  console.error(`::error ${where},title=${TITLE}::${message}`);
}

function fail(message) {
  console.error(`::error title=${TITLE}::${message}`);
  process.exit(2);
}

// Comment lines are not what a job does. `measure-disk-space.yml` explains its
// push in prose two hundred lines above making it, and release.yml's version
// bump says "Not a bare `git push`" right before calling the helper: read
// either as code and the classification is right by accident.
//
// Full-line comments only, deliberately. Stripping to the first `#` on a line
// would eat `sed 's/#//'` and every URL fragment, and the two mistakes are not
// symmetric: over-stripping loses a real push and tells a release job to drop
// the credential it needs, which breaks the release. Under-stripping only
// reports a job that does not push, which a reader fixes in one line.
//
// The JavaScript forms are here because this file is one of the scripts the
// scan follows: the prose above - "a `git push` anywhere in that closure" -
// made every job that runs this gate look like a job that pushes.
const COMMENT_LINE = {
  '#': /^\s*#/,
  js: /^\s*(\/\/|\/?\*)/,
};

function stripComments(text, path = '') {
  const patterns = [COMMENT_LINE['#']];

  if (/\.(mjs|cjs|js)$/.test(path)) {
    patterns.push(COMMENT_LINE.js);
  }

  return text
    .split('\n')
    .filter((line) => !patterns.some((pattern) => pattern.test(line)))
    .join('\n');
}

function writesToRemote(text, path = '') {
  const code = stripComments(text, path);

  return REMOTE_WRITE.some((pattern) => pattern.test(code));
}

// Scripts a block actually runs, so the question can be asked of them too:
// apply-changesets.yml's job contains no `git push` at all, because the push
// is three lines inside the script it calls.
function referencedScripts(text, path = '') {
  const found = new Set();

  for (const line of stripComments(text, path).split('\n')) {
    for (const match of line.matchAll(/scripts\/[A-Za-z0-9._/-]*[A-Za-z0-9_-]/g)) {
      if (/\.(sh|mjs|js|py)$/.test(match[0]) && existsSync(match[0])) {
        found.add(match[0]);
      }
    }
  }

  return [...found];
}

function writesToRemoteTransitively(text, path = '', seen = new Set()) {
  if (writesToRemote(text, path)) {
    return true;
  }

  for (const script of referencedScripts(text, path)) {
    if (seen.has(script)) {
      continue;
    }

    seen.add(script);

    let body;

    try {
      body = readFileSync(script, 'utf8');
    } catch {
      continue;
    }

    if (writesToRemoteTransitively(body, script, seen)) {
      return true;
    }
  }

  return false;
}

// A workflow's jobs, or - for a composite action, which has no jobs - the whole
// file as a single unit. A composite action runs inside the calling job with
// the calling job's credentials, so the same question applies to it.
function readUnits(path, text) {
  const lines = text.split('\n');
  const jobsAt = lines.findIndex((line) => /^jobs:\s*$/.test(line));

  if (jobsAt === -1) {
    return [{ name: '(action)', start: 0, lines }];
  }

  const starts = [];

  for (let index = jobsAt + 1; index < lines.length; index++) {
    if (/^[^\s#]/.test(lines[index])) {
      break;
    }

    const match = lines[index].match(/^ {2}([A-Za-z0-9_-]+):\s*(#.*)?$/);

    if (match) {
      starts.push({ name: match[1], at: index });
    }
  }

  return starts.map((entry, position) => {
    const end = position + 1 < starts.length ? starts[position + 1].at : lines.length;

    return { name: entry.name, start: entry.at, lines: lines.slice(entry.at, end) };
  });
}

// Each `uses: actions/checkout` and the step it belongs to. The step ends at
// the next list item indented the same as the one it started on, so a `with:`
// mapping of any length is read whole and the next step's is never borrowed.
function readCheckouts(unit) {
  const found = [];

  for (let index = 0; index < unit.lines.length; index++) {
    if (!/^\s*(-\s+)?uses:\s*actions\/checkout@/.test(unit.lines[index])) {
      continue;
    }

    let begin = index;

    while (begin > 0 && !/^\s*-\s/.test(unit.lines[begin])) {
      begin--;
    }

    const indent = (unit.lines[begin].match(/^(\s*)-\s/) || [, ''])[1].length;
    let end = begin + 1;

    while (end < unit.lines.length) {
      const line = unit.lines[end];

      if (line.trim() !== '' && new RegExp(`^\\s{0,${indent}}\\S`).test(line)) {
        break;
      }

      end++;
    }

    const step = unit.lines.slice(begin, end).join('\n');

    found.push({
      line: unit.start + index + 1,
      drops: /persist-credentials:\s*false\b/.test(step),
      keeps: /persist-credentials:\s*true\b/.test(step),
    });
  }

  return found;
}

function discoverInputs() {
  return execFileSync(
    'git',
    [
      'ls-files',
      '--',
      '.github/workflows/*.yml',
      '.github/workflows/*.yaml',
      '.github/actions/*/action.yml',
      '.github/actions/*/action.yaml',
    ],
    { encoding: 'utf8' }
  )
    .split('\n')
    .filter(Boolean);
}

// `git ls-files` answers about the current directory, not about the
// repository, and every annotation here has to name a path relative to the
// root so a reader can open it (issue #121).
function anchorAtRepositoryRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    fail('not inside a git repository, so no workflow could be discovered');
  }

  return '';
}

function main() {
  const args = process.argv.slice(2);
  const startedIn = process.cwd();
  const root = anchorAtRepositoryRoot();
  process.chdir(root);

  if (args.length === 1 && args[0] === '--list-inputs') {
    for (const path of discoverInputs()) {
      console.log(path);
    }

    process.exit(0);
  }

  const files = [];
  let verbose = false;

  for (const arg of args) {
    if (arg === '--verbose') {
      verbose = true;
      continue;
    }

    if (arg.startsWith('-')) {
      fail(`unknown option '${arg}'`);
    }

    files.push(relative(root, resolve(startedIn, arg)));
  }

  const inputs = files.length > 0 ? files : discoverInputs();

  if (inputs.length === 0) {
    fail('no workflows or composite actions found; this check verified nothing');
  }

  let offenders = 0;
  let checkouts = 0;
  let broken = false;

  for (const path of inputs) {
    let text;

    try {
      text = readFileSync(path, 'utf8').replaceAll('\r\n', '\n');
    } catch (error) {
      annotate(path, 0, `cannot read: ${error.message}`);
      broken = true;
      continue;
    }

    // Every checkout in the file has to land in some job, or this check quietly
    // examined fewer than it was given - the false negative issue #121 is
    // about, in the checker written to close it. A job key the reader does not
    // recognise takes its steps with it, so count them independently and
    // refuse to report a clean result off a partial read.
    const units = readUnits(path, text);
    const declared = (text.match(/^\s*(-\s+)?uses:\s*actions\/checkout@/gm) || []).length;
    const seen = units.reduce((total, unit) => total + readCheckouts(unit).length, 0);

    if (seen !== declared) {
      annotate(
        path,
        0,
        `this file declares ${declared} checkout step(s) but only ${seen} could be attributed to a job; the check would have passed over the difference, so it is reporting instead`
      );
      broken = true;
      continue;
    }

    for (const unit of units) {
      const steps = readCheckouts(unit);

      if (steps.length === 0) {
        continue;
      }

      const pushes = writesToRemoteTransitively(unit.lines.join('\n'), path);

      for (const step of steps) {
        checkouts++;

        const where = `${path}:${unit.name}`;

        if (!step.drops && !step.keeps) {
          offenders++;
          annotate(
            path,
            step.line,
            `this checkout does not set persist-credentials, so the job token stays in git configuration for the rest of ${where} by default; ` +
              (pushes
                ? 'that job does write to the remote, so say so with `persist-credentials: true`'
                : 'nothing in that job writes to the remote, so set `persist-credentials: false`')
          );
          continue;
        }

        if (step.keeps && !pushes) {
          offenders++;
          annotate(
            path,
            step.line,
            `this checkout keeps the job token, but nothing in ${where} writes to the remote; set \`persist-credentials: false\``
          );
          continue;
        }

        if (step.drops && pushes) {
          offenders++;
          annotate(
            path,
            step.line,
            `${where} writes to the remote, but this checkout drops the job token, so that push has no credential; set \`persist-credentials: true\``
          );
          continue;
        }

        if (verbose) {
          console.log(
            `  [checkout] ${where}:${step.line} ${step.drops ? 'drops' : 'keeps'} the token; job ${pushes ? 'does' : 'does not'} push`
          );
        }
      }
    }
  }

  if (offenders > 0) {
    process.exit(1);
  }

  if (broken) {
    process.exit(2);
  }

  console.log(
    `${TITLE}.mjs: ${checkouts} checkout step(s) across ${inputs.length} file(s); each one states what happens to the job token, and it matches what its job does.`
  );
  process.exit(0);
}

main();
