#!/usr/bin/env node

/**
 * Fails when a change to a file some gate reads cannot start any workflow that
 * runs that gate.
 *
 * A `paths:` filter is the cheapest way to build a check that cannot fail. The
 * job exists, the gate works, its fixtures pass — and because the filter
 * matches none of the files the gate reads, the pull request that breaks
 * exactly what the gate was written for never starts it. Nothing is red,
 * nothing is skipped, nothing is reported: the workflow simply is not in the
 * list. `scripts.yml` ran the JavaScript syntax gate under a filter of
 * '**.sh', '.github/workflows/**', 'ubuntu/**' and 'tests/**', which matches
 * no .mjs path in this repository (issue #121);
 * experiments/reproduce-issue121-workflow-trigger-gap.sh measures it.
 *
 * Two questions, one rule. For every script a workflow runs:
 *
 *   1. the files it DISCOVERS — everything `<script> --list-inputs` prints;
 *   2. the script ITSELF — editing a gate has to re-run that gate.
 *
 * Reachability is a union, not a per-workflow requirement. `measure-disk-space`
 * runs check-heredoc-vars.sh as a preflight over its own generated script; that
 * does not make every shell file in the repository a reason to spend three
 * hours measuring disk. The question this asks is whether a change to a file
 * can start *some* workflow that runs the gate — which is what "the check can
 * fail" means — and `scripts.yml` is where the repository-wide answer lives.
 *
 * Scope: `scripts/` paths named in a workflow's `run:` lines. Composite
 * actions under .github/actions/ are deliberately not included — every
 * workflow's filter would have to name them, and `workflows.yml` already lints
 * them on any change.
 *
 * Usage:
 *   node scripts/ci/check-workflow-path-coverage.mjs [--verbose] [workflow.yml]...
 *   node scripts/ci/check-workflow-path-coverage.mjs --list-inputs
 *
 * Exit codes:
 *   0 = every gate can be started by every file it reads
 *   1 = at least one file cannot start any workflow that reads it
 *   2 = the check could not run (unreadable file, a gate that will not list
 *       its inputs, bad usage)
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { basename, relative, resolve } from 'node:path';

// Scripts under scripts/ci/ that discover files with `git ls-files` and are
// still not required to answer --list-inputs, with the reason. The check below
// is two-sided: a script in this list that *does* answer --list-inputs is an
// error too, so the list cannot quietly grow to hide a real gate.
const NO_DISCOVERY_CONTRACT = new Map([
  [
    'detect-changes.sh',
    'classifies a diff range to decide what to build; its `git ls-files` is the fallback when no range resolves, not a checked file set',
  ],
  [
    'run-precommit-checks.sh',
    'runs the other gates over the staged index; it is the git hook, and no workflow runs it',
  ],
]);

// GitHub's filter syntax, as the workflow parser implements it: `*` does not
// cross a slash, `**` does, `?` is one non-slash character, and the pattern is
// matched against the whole path from the repository root.
function patternToRegExp(pattern) {
  let source = '';

  for (let index = 0; index < pattern.length; index++) {
    const character = pattern[index];

    if (character === '*') {
      if (pattern.slice(index, index + 2) === '**') {
        source += '.*';
        index++;
        continue;
      }

      source += '[^/]*';
      continue;
    }

    if (character === '?') {
      source += '[^/]';
      continue;
    }

    source += character.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }

  return new RegExp(`^${source}$`);
}

// A line-based reader rather than a YAML dependency: this repository has no
// package.json at its root, and the shape being read is two levels deep.
// Returns, per event, either an array of patterns, `ALL` when the event exists
// with no paths filter, or nothing when the workflow does not have the event.
const ALL = Symbol('every path');

function readTriggers(workflowText) {
  const lines = workflowText.split('\n');
  const start = lines.findIndex((line) => /^on:\s*$/.test(line));
  const triggers = new Map();

  if (start === -1) {
    return triggers;
  }

  let event = null;
  let inPaths = false;
  let pathsLine = 0;

  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index];

    if (/^[a-zA-Z]/.test(line)) {
      break;
    }

    const eventMatch = line.match(/^ {2}([a-z_]+):/);

    if (eventMatch) {
      event = eventMatch[1];
      inPaths = false;
      triggers.set(event, { patterns: ALL, line: index + 1 });
      continue;
    }

    if (!event) {
      continue;
    }

    if (/^ {4}paths:\s*$/.test(line)) {
      inPaths = true;
      pathsLine = index + 1;
      triggers.set(event, { patterns: [], line: pathsLine });
      continue;
    }

    if (inPaths) {
      const item = line.match(/^ {6}- (.+?)\s*$/);

      if (item) {
        triggers.get(event).patterns.push(item[1].replace(/^['"]|['"]$/g, ''));
        continue;
      }

      if (/^ {4}\S/.test(line)) {
        inPaths = false;
      }
    }
  }

  return triggers;
}

// Only the events a push or a pull request can start, and the two are a union:
// `measure-disk-space` spends three hours on a push to main and runs its cheap
// preflights on a pull request, so a script only the preflight reads belongs in
// the pull_request filter alone. "Changing this file starts nothing" is a claim
// about every event together, not about each one separately.
const TRIGGERING_EVENTS = ['push', 'pull_request'];

function isCalledOnly(triggers) {
  const names = [...triggers.keys()];

  return names.length > 0 && names.every((name) => name === 'workflow_call');
}

// Scripts a workflow actually runs, as opposed to scripts its comments
// mention: a commented line is skipped, and the path has to exist on disk.
function readReferencedScripts(workflowText) {
  const found = new Set();

  for (const line of workflowText.split('\n')) {
    if (/^\s*#/.test(line)) {
      continue;
    }

    for (const match of line.matchAll(/scripts\/[A-Za-z0-9._/-]*[A-Za-z0-9_-]/g)) {
      const path = match[0];

      if (/\.(sh|mjs|js|py)$/.test(path) && existsSync(path)) {
        found.add(path);
      }
    }
  }

  return [...found];
}

function declaresInputs(scriptPath) {
  try {
    return readFileSync(scriptPath, 'utf8').includes('--list-inputs');
  } catch {
    return false;
  }
}

function listInputs(scriptPath) {
  const runner = scriptPath.endsWith('.mjs') || scriptPath.endsWith('.js') ? 'node' : 'bash';
  const output = execFileSync(runner, [scriptPath, '--list-inputs'], {
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  });

  return output.split('\n').map((line) => line.trim()).filter(Boolean);
}

// The other side of NO_DISCOVERY_CONTRACT: every scripts/ci file that finds its
// own work with `git ls-files` has to be able to say what that work is, or the
// coverage question cannot be asked about it at all — and a gate nobody can ask
// about is exactly how the gap above stayed invisible.
function auditDiscoveryContract(verbose) {
  let broken = false;
  const tracked = execFileSync('git', ['ls-files', '--', 'scripts/ci'], {
    encoding: 'utf8',
  })
    .split('\n')
    .filter(Boolean);

  for (const path of tracked) {
    let text;

    try {
      text = readFileSync(path, 'utf8');
    } catch {
      continue;
    }

    const discovers = text.includes('git ls-files');
    const declares = text.includes('--list-inputs');
    const exempt = NO_DISCOVERY_CONTRACT.has(basename(path));

    if (discovers && !declares && !exempt) {
      console.error(
        `::error file=${path},title=check-workflow-path-coverage::${path} discovers files with 'git ls-files' but does not support --list-inputs, so no workflow's paths filter can be checked against what it reads`
      );
      broken = true;
      continue;
    }

    if (exempt && declares) {
      console.error(
        `::error file=${path},title=check-workflow-path-coverage::${path} is listed as having no discovery contract, but it answers --list-inputs; remove it from NO_DISCOVERY_CONTRACT in ${'scripts/ci/check-workflow-path-coverage.mjs'}`
      );
      broken = true;
      continue;
    }

    if (verbose && discovers) {
      const why = exempt ? `exempt: ${NO_DISCOVERY_CONTRACT.get(basename(path))}` : 'declares --list-inputs';
      console.log(`  [contract] ${path}: ${why}`);
    }
  }

  return broken;
}

function discoverWorkflows() {
  return execFileSync(
    'git',
    ['ls-files', '--', '.github/workflows/*.yml', '.github/workflows/*.yaml'],
    { encoding: 'utf8' }
  )
    .split('\n')
    .filter(Boolean);
}

// `git ls-files` answers about the current directory, not about the repository:
// run from a subdirectory it lists that subtree alone, with paths relative to
// it. Every question this check asks is a question about the whole repository —
// which workflows exist, which files each gate reads, which patterns those
// files have to match — and all three are patterns rooted at the top level,
// because that is where GitHub evaluates a `paths:` filter. So anchor there
// first, and re-express any explicit argument relative to the same root, so an
// annotation always names a path a reader can paste into a filter (issue #121).
function anchorAtRepositoryRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    console.error(
      '::error title=check-workflow-path-coverage::not inside a git repository, so no workflow could be discovered'
    );
    process.exit(2);
  }
}

function main() {
  const args = process.argv.slice(2);
  const startedIn = process.cwd();
  const root = anchorAtRepositoryRoot();
  process.chdir(root);

  // The same --list-inputs contract this check requires of every gate that
  // finds its own work. It is a gate like the others, so it answers like them.
  if (args.length === 1 && args[0] === '--list-inputs') {
    for (const workflow of discoverWorkflows()) {
      console.log(workflow);
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
      console.error(
        `::error title=check-workflow-path-coverage::unknown option '${arg}'`
      );
      process.exit(2);
    }

    files.push(relative(root, resolve(startedIn, arg)));
  }

  const workflows = files.length > 0 ? files : discoverWorkflows();

  if (workflows.length === 0) {
    console.error(
      '::error title=check-workflow-path-coverage::no workflows found; this check verified nothing'
    );
    process.exit(2);
  }

  let broken = auditDiscoveryContract(verbose);
  const parsed = new Map();

  for (const workflow of workflows) {
    try {
      const text = readFileSync(workflow, 'utf8').replaceAll('\r\n', '\n');

      parsed.set(workflow, {
        triggers: readTriggers(text),
        scripts: readReferencedScripts(text),
      });
    } catch (error) {
      console.error(
        `::error file=${workflow},title=check-workflow-path-coverage::cannot read workflow: ${error.message}`
      );
      broken = true;
    }
  }

  // A reusable workflow never starts a run of its own, so its filters are its
  // callers'. One level of resolution covers this repository; a chain deeper
  // than that would need the loop, and there is none.
  for (const [workflow, data] of parsed) {
    if (!isCalledOnly(data.triggers)) {
      continue;
    }

    const name = basename(workflow);
    const callers = [...parsed.entries()].filter(
      ([caller, other]) =>
        caller !== workflow &&
        !isCalledOnly(other.triggers) &&
        readFileSync(caller, 'utf8').includes(`.github/workflows/${name}`)
    );

    data.triggers = new Map();

    for (const [, caller] of callers) {
      for (const event of TRIGGERING_EVENTS) {
        const trigger = caller.triggers.get(event);

        if (!trigger) {
          continue;
        }

        const existing = data.triggers.get(event);

        if (!existing || trigger.patterns === ALL) {
          data.triggers.set(event, trigger);
          continue;
        }

        if (existing.patterns !== ALL) {
          existing.patterns = [...existing.patterns, ...trigger.patterns];
        }
      }
    }
  }

  // script -> the union of every triggering filter of every workflow that runs
  // it, plus one workflow and line to anchor the annotation on.
  const reach = new Map();

  for (const [workflow, data] of parsed) {
    for (const script of data.scripts) {
      if (!reach.has(script)) {
        reach.set(script, { patterns: [], unfiltered: false, where: null });
      }

      const entry = reach.get(script);

      for (const event of TRIGGERING_EVENTS) {
        const trigger = data.triggers.get(event);

        if (!trigger) {
          continue;
        }

        if (trigger.patterns === ALL) {
          entry.unfiltered = true;
          continue;
        }

        entry.patterns.push(...trigger.patterns);

        if (!entry.where) {
          entry.where = { file: workflow, line: trigger.line };
        }
      }
    }
  }

  let unreachable = false;

  const report = (script, where, missing, what) => {
    unreachable = true;

    const sample = missing.slice(0, 5).join(', ');
    const rest = missing.length > 5 ? `, and ${missing.length - 5} more` : '';

    console.error(
      `::error file=${where.file},line=${where.line},title=check-workflow-path-coverage::` +
        `${missing.length} ${what} of ${script} match the paths filter of no workflow that runs it, ` +
        `on any event a push or a pull request can start, so changing them runs the check nowhere: ${sample}${rest}`
    );
  };

  for (const [script, entry] of [...reach.entries()].sort()) {
    if (entry.unfiltered || !entry.where) {
      if (verbose) {
        console.log(`  [reach] ${script}: unfiltered, every change starts it`);
      }
      continue;
    }

    const matchers = entry.patterns.map(patternToRegExp);
    const covers = (path) => matchers.some((matcher) => matcher.test(path));

    if (!covers(script)) {
      report(script, entry.where, [script], 'file');
    }

    if (!declaresInputs(script)) {
      continue;
    }

    let inputs;

    try {
      inputs = listInputs(script);
    } catch (error) {
      console.error(
        `::error file=${script},title=check-workflow-path-coverage::--list-inputs failed: ${error.message}`
      );
      broken = true;
      continue;
    }

    const missing = inputs.filter((path) => !covers(path));

    if (missing.length > 0) {
      report(script, entry.where, missing, 'discovered input(s)');
    } else if (verbose) {
      console.log(`  [reach] ${script}: all ${inputs.length} discovered input(s) match`);
    }
  }

  if (unreachable) {
    process.exit(1);
  }

  if (broken) {
    process.exit(2);
  }

  console.log(
    `check-workflow-path-coverage.mjs: ${reach.size} script(s) across ${workflows.length} workflow(s); every file each one reads can start a run that runs it.`
  );
  process.exit(0);
}

main();
