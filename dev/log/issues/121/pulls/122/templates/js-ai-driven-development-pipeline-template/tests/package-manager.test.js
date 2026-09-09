import { describe, it, expect } from 'test-anywhere';
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, URL } from 'node:url';

const scriptPath = fileURLToPath(
  new URL('../scripts/check-package-manager.mjs', import.meta.url)
);
const releaseWorkflow = readFileSync('.github/workflows/release.yml', 'utf8');
const packageJson = JSON.parse(readFileSync('package.json', 'utf8'));
// The guard fixtures spawn node and write outside the sandbox, which the
// Deno leg's `--allow-read`-only test run cannot do.
const canRunGuardFixtures = typeof Deno === 'undefined';

function createFixture(pkg, extraFiles = []) {
  const root = path.join(
    tmpdir(),
    `pkg-mgr-${Math.random().toString(36).slice(2)}`
  );
  mkdirSync(root, { recursive: true });
  writeFileSync(
    path.join(root, 'package.json'),
    `${JSON.stringify(pkg, null, 2)}\n`
  );

  for (const file of extraFiles) {
    writeFileSync(path.join(root, file), '{}\n');
  }

  return root;
}

function runGuard(cwd) {
  return spawnSync('node', [scriptPath], { cwd, encoding: 'utf8' });
}

describe('package.json declares the package manager', () => {
  it('declares npm through devEngines, which detect() honours over lockfiles', () => {
    expect(packageJson.devEngines?.packageManager?.name).toBe('npm');
  });
});

describe('check-package-manager.mjs', () => {
  it('passes on this repository', () => {
    if (!canRunGuardFixtures) {
      return;
    }

    const result = runGuard(process.cwd());

    expect(result.status).toBe(0);
    expect(result.stdout).toContain('Package manager check passed');
    // deno.lock exists for the Deno test leg; the declaration outranks it.
    expect(result.stderr).toContain('deno.lock');
  });

  it('fails when neither packageManager nor devEngines is declared', () => {
    if (!canRunGuardFixtures) {
      return;
    }

    const root = createFixture({ name: 'fixture' });

    try {
      const result = runGuard(root);

      expect(result.status).toBe(1);
      expect(result.stderr).toContain(
        'declares neither "packageManager" nor "devEngines.packageManager"'
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('fails on a declaration naming a manager the flow cannot use', () => {
    if (!canRunGuardFixtures) {
      return;
    }

    const root = createFixture({
      name: 'fixture',
      devEngines: { packageManager: { name: 'bun' } },
    });

    try {
      const result = runGuard(root);

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('requires "npm"');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('parses a versioned packageManager field', () => {
    if (!canRunGuardFixtures) {
      return;
    }

    const root = createFixture({
      name: 'fixture',
      packageManager: 'npm@10.9.1',
    });

    try {
      const result = runGuard(root);

      expect(result.status).toBe(0);
      expect(result.stdout).toContain('declared "npm@10.9.1"');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('warns but passes when a foreign lockfile sits under a declaration', () => {
    if (!canRunGuardFixtures) {
      return;
    }

    const root = createFixture(
      { name: 'fixture', devEngines: { packageManager: { name: 'npm' } } },
      ['bun.lock', 'deno.lock']
    );

    try {
      const result = runGuard(root);

      expect(result.status).toBe(0);
      expect(result.stderr).toContain('::warning::');
      expect(result.stderr).toContain('bun.lock');
      expect(result.stderr).toContain('deno.lock');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('fails and names the lockfile when a foreign lockfile has no declaration', () => {
    if (!canRunGuardFixtures) {
      return;
    }

    const root = createFixture({ name: 'fixture' }, ['deno.lock']);

    try {
      const result = runGuard(root);

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('deno.lock');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it('runs ahead of the install step in the release workflow', () => {
    // Several jobs in release.yml install dependencies; the guard has to
    // precede the install step that follows it in the Release job.
    const checkStep = releaseWorkflow.indexOf(
      'Check package manager declaration and lockfiles'
    );
    const installStep = releaseWorkflow.indexOf(
      'name: Install dependencies',
      checkStep
    );

    expect(checkStep).toBeGreaterThan(-1);
    expect(installStep).toBeGreaterThan(checkStep);
    expect(releaseWorkflow).toContain(
      'run: node scripts/check-package-manager.mjs'
    );
  });
});
