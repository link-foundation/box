#!/usr/bin/env node

/**
 * Fails when a workflow's execution budgets do not fit inside the job caps that
 * back them up.
 *
 * Why this exists (issue #121). `timeout-minutes` is a backstop, not a
 * deadline: GitHub reports a job it kills as *cancelled*, stops the job where
 * it stands - so the `if: always()` reporting steps never run - and names
 * neither the step nor the number it exceeded. The fix is for the long steps to
 * own deadlines of their own (scripts/ci/run-with-budget-warning.sh, or a
 * step-level `timeout-minutes` where the step is a `uses:` and cannot be
 * wrapped), leaving the job cap as the outer safety net.
 *
 * That arrangement only works while the budgets stay strictly inside the cap.
 * A budget equal to its cap is a budget that never fires: the job is cancelled
 * first and the diagnosis is lost again - a check that cannot fail, which is
 * the defect class issue #121 is about. So each budget, and the total of the
 * budgets that can run in one job, must stay under MAX_BUDGET_SHARE_PERCENT of
 * the cap.
 *
 * Ported from the reference template's tests/ci-timeouts.test.js
 * (link-foundation/js-ai-driven-development-pipeline-template) with one
 * addition that repository does not need: **per-matrix-leg evaluation**. This
 * repository sizes both caps and budgets per leg -
 * `timeout-minutes: ${{ matrix.variant == 'full' && 90 || 60 }}` over a
 * 14-variant matrix - and a checker that could only take a worst case would
 * report violations no real leg can incur, which is a false positive of exactly
 * the kind being fixed here. Each leg is therefore enumerated from
 * `strategy.matrix`, substituted into the expressions, and checked on its own.
 *
 * Usage:
 *   node scripts/ci/check-timeout-budgets.mjs <workflow.yml>...
 *
 * Environment:
 *   MAX_BUDGET_SHARE_PERCENT   share of a job cap the budgets may claim (70)
 *   BOX_VERBOSE=1              print every job/leg that was checked, not only
 *                              the failures
 *
 * Exit codes:
 *   0 = every budget fits its cap
 *   1 = a budget, or a leg's concurrent total, exceeds the allowed share
 *   2 = the check could not run (unreadable file, unparseable budget or cap)
 */

import { readFileSync } from 'node:fs';

const MAX_BUDGET_SHARE_PERCENT = Number(
  process.env.MAX_BUDGET_SHARE_PERCENT ?? 70
);
const VERBOSE = process.env.BOX_VERBOSE === '1';

// A value the restricted evaluator below could not determine - `github.*`,
// `needs.*`, `steps.*.outcome` and everything else that is only known at run
// time. Distinct from `undefined`, which would read as "absent".
const UNKNOWN = Symbol('unknown');

/* ------------------------------------------------------------------ *
 * Expression evaluation
 *
 * A deliberately small subset of GitHub's expression language: string and
 * number literals, `matrix.<key>`, `==`, `!=`, `!`, `&&`, `||` and
 * parentheses. `&&` and `||` return an *operand*, not a boolean, which is what
 * makes `${{ matrix.variant == 'full' && 90 || 60 }}` a number.
 * ------------------------------------------------------------------ */

const TOKEN = /\s*(?:('(?:[^']|'')*')|(\d+(?:\.\d+)?)|(==|!=|&&|\|\||[()!])|([A-Za-z_][A-Za-z0-9_.-]*))/y;

function tokenize(source) {
  const tokens = [];
  TOKEN.lastIndex = 0;

  while (TOKEN.lastIndex < source.length) {
    const match = TOKEN.exec(source);

    if (!match) {
      return null;
    }

    const [, string, number, operator, identifier] = match;

    if (string !== undefined) {
      tokens.push({ kind: 'literal', value: string.slice(1, -1).replaceAll("''", "'") });
    } else if (number !== undefined) {
      tokens.push({ kind: 'literal', value: Number(number) });
    } else if (operator !== undefined) {
      tokens.push({ kind: operator });
    } else {
      tokens.push({ kind: 'name', value: identifier });
    }
  }

  return tokens;
}

function isTruthy(value) {
  return value !== false && value !== 0 && value !== '' && value !== null;
}

function parseExpression(tokens, matrixLeg) {
  let position = 0;

  const peek = () => tokens[position]?.kind;
  const take = (kind) => (peek() === kind ? (position++, true) : false);

  function primary() {
    if (take('(')) {
      const value = or();

      if (!take(')')) {
        throw new Error('unbalanced parenthesis');
      }

      return value;
    }

    if (take('!')) {
      const value = primary();
      return value === UNKNOWN ? UNKNOWN : !isTruthy(value);
    }

    const token = tokens[position++];

    if (!token) {
      throw new Error('unexpected end of expression');
    }

    if (token.kind === 'literal') {
      return token.value;
    }

    if (token.kind === 'name') {
      if (token.value === 'true') return true;
      if (token.value === 'false') return false;
      if (token.value === 'null') return null;

      const matrixKey = token.value.match(/^matrix\.([A-Za-z0-9_-]+)$/);

      if (matrixKey && Object.hasOwn(matrixLeg, matrixKey[1])) {
        return matrixLeg[matrixKey[1]];
      }

      // A call - `cancelled()`, `fromJSON(...)` - or a context this evaluator
      // does not model. Skip its argument list so parsing can continue.
      if (take('(')) {
        let depth = 1;

        while (depth > 0) {
          if (position >= tokens.length) {
            throw new Error('unbalanced parenthesis');
          }

          if (tokens[position].kind === '(') depth++;
          if (tokens[position].kind === ')') depth--;
          position++;
        }
      }

      return UNKNOWN;
    }

    throw new Error(`unexpected token '${token.kind}'`);
  }

  function equality() {
    let left = primary();

    for (;;) {
      const negated = peek() === '!=';

      if (!take('==') && !negated) {
        return left;
      }

      if (negated) position++;

      const right = primary();

      left =
        left === UNKNOWN || right === UNKNOWN
          ? UNKNOWN
          : negated
            ? left !== right
            : left === right;
    }
  }

  function and() {
    let left = equality();

    while (take('&&')) {
      const right = equality();

      // GitHub returns an operand, not a boolean: `false && x` is `false`,
      // which is what makes `matrix.variant == 'full' && 90 || 60` a number.
      left = left === UNKNOWN ? UNKNOWN : isTruthy(left) ? right : left;
    }

    return left;
  }

  function or() {
    let left = and();

    while (take('||')) {
      const right = and();
      left = left === UNKNOWN ? UNKNOWN : isTruthy(left) ? left : right;
    }

    return left;
  }

  const value = or();

  if (position !== tokens.length) {
    throw new Error('trailing tokens');
  }

  return value;
}

// Evaluates a workflow expression for one matrix leg. `${{ ... }}` wrappers are
// stripped; a bare condition (the form `if:` accepts) is evaluated as written.
// Returns UNKNOWN when the value depends on something only the runner knows.
function evaluate(source, matrixLeg) {
  const text = source.trim();

  if (text === '') {
    return UNKNOWN;
  }

  const wrapped = text.match(/^\$\{\{(.*)\}\}$/s);
  const body = wrapped ? wrapped[1] : text;

  // A string with an interpolation embedded in it is not an expression.
  if (!wrapped && body.includes('${{')) {
    return UNKNOWN;
  }

  const tokens = tokenize(body.trim());

  if (!tokens) {
    return UNKNOWN;
  }

  try {
    return parseExpression(tokens, matrixLeg);
  } catch {
    return UNKNOWN;
  }
}

/* ------------------------------------------------------------------ *
 * Workflow parsing
 *
 * Line-oriented, like scripts/ci/check-status-gate-covers-all-jobs.mjs, so the
 * check has no dependencies and runs from a bare checkout.
 * ------------------------------------------------------------------ */

function listJobs(workflowText) {
  const jobsStart = workflowText.indexOf('\njobs:\n');

  if (jobsStart === -1) {
    return [];
  }

  return Array.from(
    workflowText.slice(jobsStart).matchAll(/^ {2}([a-zA-Z0-9_-]+):\s*$/gm),
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

// Reads a `key: value` mapping that starts at `indent` spaces. Block scalars
// (`|`, `>`) are folded into one line, which is all the callers need.
function parseMapping(lines, startIndex, indent) {
  const mapping = {};
  const keyPattern = new RegExp(`^ {${indent}}([A-Za-z0-9_-]+):(.*)$`);

  for (let index = startIndex; index < lines.length; index++) {
    const line = lines[index];

    if (line.trim() === '' || /^\s*#/.test(line)) {
      continue;
    }

    const match = line.match(keyPattern);

    if (!match) {
      break;
    }

    let value = match[2].trim();

    if (value === '|' || value === '>' || value === '|-' || value === '>-') {
      const parts = [];

      while (
        index + 1 < lines.length &&
        (lines[index + 1].trim() === '' ||
          lines[index + 1].startsWith(' '.repeat(indent + 1)))
      ) {
        parts.push(lines[++index].trim());
      }

      value = parts.join(' ').trim();
    }

    mapping[match[1]] = value.replace(/^['"]|['"]$/g, '');
  }

  return mapping;
}

function findMapping(block, keyLine, indent) {
  const lines = block.split('\n');
  const start = lines.findIndex((line) => line === keyLine);

  return start === -1 ? {} : parseMapping(lines, start + 1, indent);
}

function getScalar(block, indent, key) {
  const lines = block.split('\n');
  const pattern = new RegExp(`^ {${indent}}${key}:(.*)$`);

  for (let index = 0; index < lines.length; index++) {
    const match = lines[index].match(pattern);

    if (!match) {
      continue;
    }

    let value = match[1].trim();

    if (value === '|' || value === '>' || value === '|-' || value === '>-') {
      const parts = [];

      while (
        index + 1 < lines.length &&
        (lines[index + 1].trim() === '' ||
          lines[index + 1].startsWith(' '.repeat(indent + 1)))
      ) {
        parts.push(lines[++index].trim());
      }

      value = parts.join(' ');
    }

    // Strip a trailing comment, but only outside an expression: the caps in
    // this repository are commented inline (`timeout-minutes: 45    # ...`).
    return value.replace(/\s+#(?![^${]*\}\}).*$/, '').trim();
  }

  return null;
}

// `strategy.matrix` in its flow form (`key: [a, b, c]`), which is the only form
// this repository uses. An `include:`/`exclude:` key is reported as unreadable
// rather than silently ignored.
function parseMatrix(jobBlock) {
  const lines = jobBlock.split('\n');
  const start = lines.findIndex((line) => line === '      matrix:');

  if (start === -1) {
    return { legs: [{}], readable: true };
  }

  const dimensions = {};
  let readable = true;

  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index];

    if (line.trim() === '' || /^\s*#/.test(line)) {
      continue;
    }

    if (!line.startsWith('        ')) {
      break;
    }

    const flow = line.match(/^ {8}([A-Za-z0-9_-]+):\s*\[(.*)\]\s*$/);

    if (!flow) {
      readable = false;
      break;
    }

    dimensions[flow[1]] = flow[2]
      .split(',')
      .map((value) => value.trim().replace(/^['"]|['"]$/g, ''))
      .filter(Boolean);
  }

  let legs = [{}];

  for (const [key, values] of Object.entries(dimensions)) {
    legs = legs.flatMap((leg) => values.map((value) => ({ ...leg, [key]: value })));
  }

  return { legs, readable };
}

function splitStepBlocks(jobBlock) {
  const lines = jobBlock.split('\n');
  const start = lines.findIndex((line) => line === '    steps:');

  if (start === -1) {
    return [];
  }

  const steps = [];
  let current = null;

  for (const line of lines.slice(start + 1)) {
    if (/^ {6}- /.test(line)) {
      if (current) steps.push(current.join('\n'));
      current = [line.replace(/^ {6}- /, '        ')];
      continue;
    }

    if (current) current.push(line);
  }

  if (current) steps.push(current.join('\n'));

  return steps;
}

/* ------------------------------------------------------------------ *
 * Budgets
 * ------------------------------------------------------------------ */

const WRAPPER = 'run-with-budget-warning.sh';

function resolveSeconds(argument, environments, matrixLeg) {
  const variable = argument.match(/^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?$/);
  let source = argument.replace(/^['"]|['"]$/g, '');

  if (variable) {
    const name = variable[1];
    const holder = environments.find((environment) => name in environment);

    if (!holder) {
      return { ok: false, reason: `no env value for $${name}` };
    }

    source = holder[name];
  }

  if (/^\d+$/.test(source)) {
    return { ok: true, seconds: Number(source) };
  }

  const value = evaluate(source, matrixLeg);

  if (typeof value === 'number') {
    return { ok: true, seconds: value };
  }

  if (typeof value === 'string' && /^\d+$/.test(value)) {
    return { ok: true, seconds: Number(value) };
  }

  return { ok: false, reason: `cannot resolve '${source}' to a number of seconds` };
}

// Every budget a step declares: the wrapper invocations in its `run:` block,
// plus the step-level `timeout-minutes` GitHub applies to a `uses:` step that
// cannot be wrapped. Both are deadlines the step owns, so both count.
function getStepBudget(stepBlock, environments, matrixLeg, problems, where) {
  let seconds = 0;

  // Comment lines are dropped first: the wrapper is named in the prose that
  // explains it as often as it is called, and reading `run-with-budget-warning.sh
  // (issue #121)` out of a comment as a budget of "(issue" would fail this check
  // on a file that is correct - a false positive, in the checker written to
  // remove them.
  const executable = stepBlock
    .split('\n')
    .filter((line) => !/^\s*#/.test(line))
    .join('\n');

  for (const match of executable.matchAll(
    new RegExp(`${WRAPPER}\\s+(\\S+)`, 'g')
  )) {
    const resolved = resolveSeconds(match[1], environments, matrixLeg);

    if (!resolved.ok) {
      problems.push(`${where}: ${resolved.reason}`);
      continue;
    }

    seconds += resolved.seconds;
  }

  const stepTimeout = getScalar(stepBlock, 8, 'timeout-minutes');

  if (stepTimeout !== null) {
    const value = /^\d+$/.test(stepTimeout)
      ? Number(stepTimeout)
      : evaluate(stepTimeout, matrixLeg);

    if (typeof value === 'number') {
      seconds += value * 60;
    } else {
      problems.push(`${where}: cannot resolve step timeout-minutes '${stepTimeout}'`);
    }
  }

  return seconds;
}

/* ------------------------------------------------------------------ *
 * The check
 * ------------------------------------------------------------------ */

function checkJob(file, jobName, jobBlock, workflowEnv, problems, violations) {
  // A job that delegates to a reusable workflow cannot declare
  // `timeout-minutes` at all - GitHub rejects the key on a `uses:` job - and
  // has no steps of its own. Its budgets live in the called workflow.
  if (/^ {4}uses:/m.test(jobBlock)) {
    if (VERBOSE) {
      console.log(`${file}: ${jobName} calls a reusable workflow; nothing to size here.`);
    }

    return;
  }

  const cap = getScalar(jobBlock, 4, 'timeout-minutes');

  if (cap === null) {
    violations.push(
      `::error file=${file}::job '${jobName}' declares no timeout-minutes, so nothing bounds it`
    );
    return;
  }

  const { legs, readable } = parseMatrix(jobBlock);

  if (!readable) {
    problems.push(`${file}: job '${jobName}' has a matrix this check cannot read`);
    return;
  }

  const jobEnv = findMapping(jobBlock, '    env:', 6);
  const steps = splitStepBlocks(jobBlock);

  for (const leg of legs) {
    const legName = Object.entries(leg)
      .map(([key, value]) => `${key}=${value}`)
      .join(', ');
    const where = legName ? `${jobName} [${legName}]` : jobName;
    const capValue = /^\d+$/.test(cap) ? Number(cap) : evaluate(cap, leg);

    if (typeof capValue !== 'number') {
      problems.push(`${file}: ${where}: cannot resolve timeout-minutes '${cap}'`);
      continue;
    }

    const capSeconds = capValue * 60;
    const allowed = (capSeconds * MAX_BUDGET_SHARE_PERCENT) / 100;
    const conditionalGroups = new Map();
    let unconditional = 0;

    for (const stepBlock of steps) {
      const stepEnv = findMapping(stepBlock, '        env:', 10);
      const environments = [stepEnv, jobEnv, workflowEnv];
      const budget = getStepBudget(stepBlock, environments, leg, problems, `${file}: ${where}`);

      if (budget === 0) {
        continue;
      }

      const stepName = getScalar(stepBlock, 8, 'name') ?? '(unnamed step)';

      if (budget > allowed) {
        violations.push(
          `::error file=${file}::${where}: step '${stepName}' budgets ${budget}s, ` +
            `${share(budget, capSeconds)} of the ${capSeconds}s cap ` +
            `(limit ${MAX_BUDGET_SHARE_PERCENT}%)`
        );
      }

      const condition = getScalar(stepBlock, 8, 'if');
      const conditionValue = condition === null ? true : evaluate(condition, leg);

      if (conditionValue !== UNKNOWN && !isTruthy(conditionValue)) {
        continue;
      }

      if (condition === null || conditionValue === true) {
        unconditional += budget;
        continue;
      }

      conditionalGroups.set(condition, (conditionalGroups.get(condition) ?? 0) + budget);
    }

    // Steps sharing one condition run together; steps under different
    // conditions may not, so the charge is the largest single group. This is
    // deliberately an under-approximation - two conditions this evaluator
    // cannot decide (`github.event_name == 'push'` and the like) might both
    // hold on the same run, and only the larger is charged. The alternative
    // errs the other way, summing groups that provably exclude each other:
    // pr-test-dind would be charged for all fourteen variants at once, a
    // failure no run can produce. A false alarm on every run trains people to
    // ignore the check; the 30% headroom this limit reserves is what covers
    // the under-count.
    const largestGroup = Math.max(0, ...conditionalGroups.values());
    const total = unconditional + largestGroup;

    if (total > allowed) {
      violations.push(
        `::error file=${file}::${where}: budgets total ${total}s, ` +
          `${share(total, capSeconds)} of the ${capSeconds}s cap ` +
          `(limit ${MAX_BUDGET_SHARE_PERCENT}%). Raise timeout-minutes or shorten a budget.`
      );
      continue;
    }

    if (VERBOSE) {
      console.log(
        `${file}: ${where}: cap ${capValue}m, budgets ${total}s (${share(total, capSeconds)}).`
      );
    }
  }
}

function share(part, whole) {
  return `${((part / whole) * 100).toFixed(1)}%`;
}

function main() {
  const files = process.argv.slice(2);

  if (files.length === 0) {
    console.error('Usage: node scripts/ci/check-timeout-budgets.mjs <workflow.yml>...');
    process.exit(2);
  }

  const problems = [];
  const violations = [];

  for (const file of files) {
    let workflowText;

    try {
      workflowText = readFileSync(file, 'utf8').replaceAll('\r\n', '\n');
    } catch (error) {
      problems.push(`${file}: cannot read workflow: ${error.message}`);
      continue;
    }

    const jobs = listJobs(workflowText);

    if (jobs.length === 0) {
      problems.push(`${file}: no jobs found`);
      continue;
    }

    const workflowEnv = findMapping(workflowText, 'env:', 2);

    for (const jobName of jobs) {
      checkJob(
        file,
        jobName,
        getJobBlock(workflowText, jobName),
        workflowEnv,
        problems,
        violations
      );
    }
  }

  for (const violation of violations) {
    console.error(violation);
  }

  for (const problem of problems) {
    console.error(`::error::${problem}`);
  }

  if (violations.length > 0) {
    process.exit(1);
  }

  // An unreadable budget is not "no budget found": it is a number this check
  // was supposed to hold and could not read, which is the same silent pass the
  // whole exercise is about removing.
  if (problems.length > 0) {
    process.exit(2);
  }

  console.log(
    `Every budget in ${files.length} workflow(s) fits inside its job cap ` +
      `(limit ${MAX_BUDGET_SHARE_PERCENT}% of timeout-minutes).`
  );
  process.exit(0);
}

main();
