#!/usr/bin/env node

/**
 * Fails when a job in a workflow is missing from that workflow's terminal
 * status gate, i.e. when its failure or cancellation cannot turn the run red.
 *
 * A gate job runs `if: always()`, `needs:` every other job in the workflow, and
 * runs scripts/ci/check-pipeline-status.sh over `toJSON(needs)`. Its `needs`
 * list is hand-maintained, so a job added later and left out of it can fail
 * while the gate reports success — the gate would then be a check that cannot
 * fail, which is the defect class issue #121 is about. This script derives the
 * requirement from the workflow text itself, so the gate cannot drift from the
 * job list it is supposed to cover.
 *
 * Ported from the reference pipeline template's
 * scripts/check-status-gate-covers-all-jobs.mjs, with one addition: several
 * gate names are accepted, because this repository's five reusable release
 * workflows already named their terminal job `status` and it is referenced by
 * `jobs.status.outputs.*` in the calling workflow.
 *
 * Usage:
 *   node scripts/ci/check-status-gate-covers-all-jobs.mjs <workflow.yml>...
 *   node scripts/ci/check-status-gate-covers-all-jobs.mjs --gate a --gate b <workflow.yml>...
 *
 * Exit codes:
 *   0 = every workflow has a gate and every gate covers every other job
 *   1 = a gate has a hole: some job's result cannot fail the run
 *   2 = the check could not run (no gate job, unreadable file, bad usage)
 */

import { readFileSync } from 'node:fs';

const DEFAULT_GATE_NAMES = ['pipeline-status', 'status'];

// A `workflow_call`-only file never starts a run of its own: its conclusion is
// the conclusion of the job that called it, in a workflow that does have a
// gate. Requiring a second gate inside it would add a job per call without
// making any result reachable that was not already. Coverage is still checked
// when such a file does have one.
function isCalledOnly(workflowText) {
  const onStart = workflowText.search(/^on:\s*$/m);

  if (onStart === -1) {
    return false;
  }

  const body = workflowText.slice(onStart).split('\n').slice(1);
  const triggers = [];

  for (const line of body) {
    if (/^[a-zA-Z]/.test(line)) {
      break;
    }

    const trigger = line.match(/^ {2}([a-z_]+):/);

    if (trigger) {
      triggers.push(trigger[1]);
    }
  }

  return triggers.length > 0 && triggers.every((name) => name === 'workflow_call');
}

function listJobs(workflowText) {
  const jobsStart = workflowText.indexOf('\njobs:\n');

  if (jobsStart === -1) {
    return [];
  }

  const jobsBody = workflowText.slice(jobsStart);

  return Array.from(
    jobsBody.matchAll(/^ {2}([a-zA-Z0-9_-]+):\s*$/gm),
    (match) => match[1]
  );
}

function getJobBlock(workflowText, jobName) {
  const lines = workflowText.split('\n');
  const start = lines.findIndex((line) => line === `  ${jobName}:`);

  if (start === -1) {
    return '';
  }

  const end = lines.findIndex(
    (line, index) => index > start && /^ {2}[a-zA-Z0-9_-]+:\s*$/.test(line)
  );

  return lines.slice(start, end === -1 ? lines.length : end).join('\n');
}

// `needs` accepts both the flow form (`needs: [a, b]`) and the block form (one
// `- name` list item per line); this repository's workflows use both.
function listNeededJobs(jobBlock) {
  const flow = jobBlock.match(/^ {4}needs:\s*\[(.+)\]\s*$/m);

  if (flow) {
    return flow[1]
      .split(',')
      .map((job) => job.trim().replace(/^['"]|['"]$/g, ''))
      .filter(Boolean);
  }

  const lines = jobBlock.split('\n');
  const needsStart = lines.findIndex((line) => line === '    needs:');

  if (needsStart === -1) {
    return [];
  }

  const neededJobs = [];

  for (const line of lines.slice(needsStart + 1)) {
    const item = line.match(/^ {6}- ([a-zA-Z0-9_-]+)\s*$/);

    if (!item) {
      break;
    }

    neededJobs.push(item[1]);
  }

  return neededJobs;
}

function main() {
  const args = process.argv.slice(2);
  const gateNames = [];
  const files = [];

  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--gate') {
      const name = args[++index];

      if (!name) {
        console.error('::error::--gate requires a job name');
        process.exit(2);
      }

      gateNames.push(name);
      continue;
    }

    files.push(args[index]);
  }

  const gates = gateNames.length > 0 ? gateNames : DEFAULT_GATE_NAMES;

  if (files.length === 0) {
    console.error(
      'Usage: node scripts/ci/check-status-gate-covers-all-jobs.mjs [--gate <name>]... <workflow.yml>...'
    );
    process.exit(2);
  }

  let holes = false;
  let broken = false;

  for (const file of files) {
    let workflowText;

    try {
      // Normalise line endings: a Windows checkout stores CRLF, and the
      // job-block matcher below compares whole lines.
      workflowText = readFileSync(file, 'utf8').replaceAll('\r\n', '\n');
    } catch (error) {
      console.error(
        `::error file=${file}::cannot read workflow: ${error.message}`
      );
      broken = true;
      continue;
    }

    const jobs = listJobs(workflowText);

    if (jobs.length === 0) {
      console.error(`::error file=${file}::no jobs found`);
      broken = true;
      continue;
    }

    const gateName = gates.find((name) => jobs.includes(name));

    if (!gateName) {
      if (isCalledOnly(workflowText)) {
        console.log(
          `${file}: no gate needed; a workflow_call file reports through the job that calls it.`
        );
        continue;
      }

      console.error(
        `::error file=${file}::no terminal status gate: expected a job named ${gates
          .map((name) => `'${name}'`)
          .join(' or ')}`
      );
      broken = true;
      continue;
    }

    const neededJobs = listNeededJobs(getJobBlock(workflowText, gateName));
    const missingJobs = jobs.filter(
      (job) => job !== gateName && !neededJobs.includes(job)
    );

    if (missingJobs.length > 0) {
      holes = true;

      for (const job of missingJobs) {
        console.error(
          `::error file=${file}::job '${job}' is not in ${gateName}.needs; its result cannot fail the run`
        );
      }

      continue;
    }

    console.log(
      `${file}: ${gateName} covers all ${jobs.length - 1} other job(s).`
    );
  }

  // Exit 1 ("the gate has a hole") and exit 2 ("the gate is missing or the
  // check could not run") name different fixes; a hole wins when both appear
  // because the holes are the actionable findings.
  if (holes) {
    process.exit(1);
  }

  if (broken) {
    process.exit(2);
  }

  process.exit(0);
}

main();
