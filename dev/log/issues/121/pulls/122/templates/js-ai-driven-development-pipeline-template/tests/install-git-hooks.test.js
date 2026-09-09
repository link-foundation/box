import { describe, it, expect } from 'test-anywhere';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const scriptPath = path.resolve('scripts/install-git-hooks.mjs');
const packageJson = JSON.parse(readFileSync('package.json', 'utf8'));
const isDenoRuntime = typeof Deno !== 'undefined';
const canRunShellFixtures =
  !isDenoRuntime &&
  typeof process !== 'undefined' &&
  process.platform !== 'win32';

// The real husky always exits 0, and the real `git config --get` exits 1
// exactly when hooks were never installed. These shims reproduce both
// behaviours under test control, with a marker file proving whether husky
// was invoked at all.
function writeShims() {
  const binPath = path.join(
    mkdtempSync(path.join(tmpdir(), 'git-hooks-bin-')),
    'bin'
  );
  mkdirSync(binPath, { recursive: true });

  const npxPath = path.join(binPath, 'npx');
  writeFileSync(
    npxPath,
    `#!/usr/bin/env bash
if [ "$1" = "husky" ]; then
  [ -n "$FAKE_NPX_MARKER" ] && echo ran > "$FAKE_NPX_MARKER"
  [ -n "$FAKE_HUSKY_MESSAGE" ] && printf '%s' "$FAKE_HUSKY_MESSAGE"
  exit "\${FAKE_HUSKY_EXIT:-0}"
fi
exit 0
`
  );
  chmodSync(npxPath, 0o755);

  const gitPath = path.join(binPath, 'git');
  writeFileSync(
    gitPath,
    `#!/usr/bin/env bash
if [ "$1" = "config" ] && [ "$2" = "--get" ]; then
  if [ -n "$FAKE_HOOKS_PATH" ]; then
    echo "$FAKE_HOOKS_PATH"
    exit 0
  fi
  exit 1
fi
exit 0
`
  );
  chmodSync(gitPath, 0o755);

  return binPath;
}

function makeWorkspace({ withGit }) {
  const root = mkdtempSync(path.join(tmpdir(), 'git-hooks-repo-'));
  if (withGit) {
    mkdirSync(path.join(root, '.git'));
  }
  return root;
}

function runPrepare(cwd, extraEnv = {}) {
  const env = { ...process.env };
  delete env.CI;
  delete env.HUSKY;
  return spawnSync('node', [scriptPath], {
    encoding: 'utf8',
    cwd,
    env: { ...env, ...extraEnv },
  });
}

describe('install-git-hooks.mjs', () => {
  it('replaces the unconditionally-masked prepare script', () => {
    expect(packageJson.scripts.prepare).toBe(
      'node scripts/install-git-hooks.mjs'
    );
    expect(packageJson.scripts.prepare).not.toContain('|| true');
    expect(packageJson.devDependencies.husky).toBeTruthy();
  });
});

describe('install-git-hooks.mjs verification', () => {
  if (!canRunShellFixtures) {
    return;
  }

  it('runs husky and passes when core.hooksPath is set', () => {
    const binPath = writeShims();
    const workspace = makeWorkspace({ withGit: true });
    const marker = path.join(workspace, 'npx-ran');

    try {
      const result = runPrepare(workspace, {
        PATH: `${binPath}${path.delimiter}${process.env.PATH ?? ''}`,
        FAKE_HOOKS_PATH: '.husky/_',
        FAKE_NPX_MARKER: marker,
      });

      expect(result.status).toBe(0);
    } finally {
      rmSync(binPath, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  });

  it('fails when husky leaves core.hooksPath unset', () => {
    const binPath = writeShims();
    const workspace = makeWorkspace({ withGit: true });

    try {
      const result = runPrepare(workspace, {
        PATH: `${binPath}${path.delimiter}${process.env.PATH ?? ''}`,
        FAKE_HUSKY_MESSAGE: ".git can't be found",
      });

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('git hooks were not installed');
      expect(result.stderr).toContain(".git can't be found");
    } finally {
      rmSync(binPath, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  });

  it('reports it when husky says nothing', () => {
    const binPath = writeShims();
    const workspace = makeWorkspace({ withGit: true });

    try {
      const result = runPrepare(workspace, {
        PATH: `${binPath}${path.delimiter}${process.env.PATH ?? ''}`,
      });

      expect(result.status).toBe(1);
      expect(result.stderr).toContain('husky said nothing');
    } finally {
      rmSync(binPath, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  });

  it('skips on CI', () => {
    const binPath = writeShims();
    const workspace = makeWorkspace({ withGit: true });
    const marker = path.join(workspace, 'npx-ran');

    try {
      const result = runPrepare(workspace, {
        PATH: `${binPath}${path.delimiter}${process.env.PATH ?? ''}`,
        CI: '1',
        FAKE_NPX_MARKER: marker,
      });

      expect(result.status).toBe(0);
      expect(() => readFileSync(marker, 'utf8')).toThrow();
    } finally {
      rmSync(binPath, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  });

  it('skips with HUSKY=0', () => {
    const binPath = writeShims();
    const workspace = makeWorkspace({ withGit: true });
    const marker = path.join(workspace, 'npx-ran');

    try {
      const result = runPrepare(workspace, {
        PATH: `${binPath}${path.delimiter}${process.env.PATH ?? ''}`,
        HUSKY: '0',
        FAKE_NPX_MARKER: marker,
      });

      expect(result.status).toBe(0);
      expect(() => readFileSync(marker, 'utf8')).toThrow();
    } finally {
      rmSync(binPath, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  });

  it('skips outside a git repository', () => {
    const binPath = writeShims();
    const workspace = makeWorkspace({ withGit: false });
    const marker = path.join(workspace, 'npx-ran');

    try {
      const result = runPrepare(workspace, {
        PATH: `${binPath}${path.delimiter}${process.env.PATH ?? ''}`,
        FAKE_NPX_MARKER: marker,
      });

      expect(result.status).toBe(0);
      expect(() => readFileSync(marker, 'utf8')).toThrow();
    } finally {
      rmSync(binPath, { recursive: true, force: true });
      rmSync(workspace, { recursive: true, force: true });
    }
  });
});
