import { describe, it, expect } from 'test-anywhere';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath, URL } from 'node:url';

const workflow = readFileSync(
  '.github/workflows/release.yml',
  'utf8'
).replaceAll('\r\n', '\n');
const workflowNames = [
  'release.yml',
  'links.yml',
  'security.yml',
  'workflows.yml',
  'example-app.yml',
];
const gatedWorkflows = Object.fromEntries(
  workflowNames.map((name) => [
    name,
    readFileSync(`.github/workflows/${name}`, 'utf8').replaceAll('\r\n', '\n'),
  ])
);
const scriptPath = fileURLToPath(
  new URL('../scripts/check-pipeline-status.sh', import.meta.url)
);
const canRunBash =
  typeof Deno === 'undefined' &&
  typeof process !== 'undefined' &&
  process.platform !== 'win32';

function listWorkflowJobs(source) {
  const jobsStart = source.indexOf('\njobs:\n');
  const jobsBody = jobsStart === -1 ? '' : source.slice(jobsStart);

  return Array.from(
    jobsBody.matchAll(/^[ ]{2}([a-zA-Z0-9_-]+):\s*$/gm),
    (match) => match[1]
  );
}

function getJobBlock(source, jobName) {
  const lines = source.split('\n');
  const start = lines.findIndex((line) => line === `  ${jobName}:`);

  if (start === -1) {
    return '';
  }

  const end = lines.findIndex(
    (line, index) => index > start && /^[ ]{2}[a-zA-Z0-9_-]+:\s*$/.test(line)
  );

  return lines.slice(start, end === -1 ? lines.length : end).join('\n');
}

function listNeededJobs(jobBlock) {
  const lines = jobBlock.split('\n');
  const needsStart = lines.findIndex((line) => line === '    needs:');

  if (needsStart === -1) {
    return [];
  }

  const neededJobs = [];

  for (const line of lines.slice(needsStart + 1)) {
    const item = line.match(/^[ ]{6}- ([a-zA-Z0-9_-]+)\s*$/);

    if (!item) {
      break;
    }

    neededJobs.push(item[1]);
  }

  return neededJobs;
}

function runGate(needs, isMain = false, extraEnv = {}) {
  return spawnSync('bash', [scriptPath], {
    encoding: 'utf8',
    env: {
      ...process.env,
      NEEDS_JSON: JSON.stringify(needs),
      IS_MAIN: String(isMain),
      ...extraEnv,
    },
  });
}

describe('pipeline status gate', () => {
  it('observes every other release workflow job', () => {
    const jobs = listWorkflowJobs(workflow);
    const gate = getJobBlock(workflow, 'pipeline-status');

    expect(gate).toContain('    if: always()');
    expect(gate).toContain('uses: actions/setup-node@v6');
    expect(gate).toContain('NEEDS_JSON: ${{ toJSON(needs) }}');
    expect(gate).toContain(
      "IS_MAIN: ${{ github.ref == 'refs/heads/main' && github.event_name == 'push' }}"
    );
    expect(gate).toContain('RUN_SHA: ${{ github.sha }}');
    expect(listNeededJobs(gate).sort()).toEqual(
      jobs.filter((job) => job !== 'pipeline-status').sort()
    );
  });

  it('does not cancel superseded jobs on main', () => {
    expect(workflow).not.toContain('      cancel-in-progress: true');
    expect(workflow).toContain(
      "      cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}"
    );
  });

  if (canRunBash) {
    it('passes when jobs succeeded or were skipped', () => {
      const result = runGate({
        lint: { result: 'success' },
        release: { result: 'skipped' },
      });

      expect(result.status).toBe(0);
      expect(result.stdout).toContain('Failed jobs:    <none>');
      expect(result.stdout).toContain('Cancelled jobs: <none>');
    });

    it('fails for a failed job on every ref', () => {
      const result = runGate({ lint: { result: 'failure' } });

      expect(result.status).toBe(1);
      expect(result.stdout).toContain('Pipeline failed. Failing jobs: lint');
    });

    it('fails for a cancelled job on main', () => {
      const result = runGate({ release: { result: 'cancelled' } }, true);

      expect(result.status).toBe(1);
      expect(result.stdout).toContain(
        'Pipeline has cancelled jobs on main: release'
      );
    });

    it('warns for a cancelled job on a non-default ref', () => {
      const result = runGate({ test: { result: 'cancelled' } });

      expect(result.status).toBe(0);
      expect(result.stdout).toContain('::warning::Cancelled jobs: test');
    });
  }
});

describe('pipeline status gate in every workflow', () => {
  it('gates every workflow and observes every other job', () => {
    const problems = [];

    for (const [name, source] of Object.entries(gatedWorkflows)) {
      const jobs = listWorkflowJobs(source);
      const gate = getJobBlock(source, 'pipeline-status');

      if (!jobs.includes('pipeline-status')) {
        problems.push(`${name}: no pipeline-status gate job`);
        continue;
      }

      const covered = listNeededJobs(gate).sort();
      const expected = jobs.filter((job) => job !== 'pipeline-status').sort();

      if (covered.join(',') !== expected.join(',')) {
        problems.push(
          `${name}: gate needs [${covered}] does not cover [${expected}]`
        );
      }

      if (!gate.includes('RUN_SHA: ${{ github.sha }}')) {
        problems.push(`${name}: gate does not pass RUN_SHA`);
      }

      if (!gate.includes('run: bash scripts/check-pipeline-status.sh')) {
        problems.push(`${name}: gate does not run the gate script`);
      }
    }

    expect(problems).toEqual([]);
  });

  it('uses a status function, so the gate runs when its needs fail', () => {
    const problems = [];

    for (const [name, source] of Object.entries(gatedWorkflows)) {
      const gate = getJobBlock(source, 'pipeline-status');

      if (!gate.includes('!cancelled()') && !gate.includes('always()')) {
        problems.push(`${name}: gate has no status function in its if`);
      }
    }

    expect(problems).toEqual([]);
  });

  it('bounds the new gate jobs at 5 minutes', () => {
    for (const name of [
      'links.yml',
      'security.yml',
      'workflows.yml',
      'example-app.yml',
    ]) {
      const gate = getJobBlock(gatedWorkflows[name], 'pipeline-status');

      expect(gate).toContain('    timeout-minutes: 5');
    }
  });
});

describe('pipeline status supersede detection', () => {
  const cancelled = { lint: { result: 'cancelled' } };

  if (canRunBash) {
    it('errors when main is at the run commit (a genuine overrun)', () => {
      const result = runGate(cancelled, true, {
        RUN_SHA: 'aaa111',
        BRANCH_HEAD_SHA: 'aaa111',
      });

      expect(result.status).toBe(1);
      expect(result.stdout).toContain(
        'Pipeline has cancelled jobs on main: lint'
      );
    });

    it('warns when the branch has moved past this run (a supersede)', () => {
      const result = runGate(cancelled, true, {
        RUN_SHA: 'aaa111',
        BRANCH_HEAD_SHA: 'bbb222',
      });

      expect(result.status).toBe(0);
      expect(result.stdout).toContain('::warning::Cancelled jobs: lint');
      expect(result.stdout).toContain(
        'This run tests aaa111; main is at bbb222.'
      );
    });

    it('errors when the branch head cannot be resolved', () => {
      const result = runGate(cancelled, true, {
        RUN_SHA: 'aaa111',
        GIT_REMOTE: 'no-such-remote',
      });

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('Could not resolve the head of main');
      expect(result.stdout).toContain(
        'Pipeline has cancelled jobs on main: lint'
      );
    });

    it('errors without a network call when RUN_SHA is missing', () => {
      const result = runGate(cancelled, true);

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('RUN_SHA is unset');
      expect(result.stdout).toContain(
        'Pipeline has cancelled jobs on main: lint'
      );
    });
  }
});
