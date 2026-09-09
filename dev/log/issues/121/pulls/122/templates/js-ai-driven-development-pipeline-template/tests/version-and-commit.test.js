import { describe, it, expect } from 'test-anywhere';
import { readFileSync } from 'node:fs';

const script = readFileSync('scripts/version-and-commit.mjs', 'utf8');
const useModule = readFileSync('scripts/use-module.mjs', 'utf8');

describe('version-and-commit.mjs formats the release commit', () => {
  it('checks staged files with prettier between staging and committing', () => {
    // The formatting logic lives in checkStagedFormatting(), which is defined
    // above main(); the ordering that matters is at the call site.
    const staged = script.indexOf('await $`git add -A`');
    const checkCall = script.indexOf('await checkStagedFormatting();');
    const prettier = script.indexOf('npx prettier --check');
    const commit = script.indexOf('await $`git commit');

    expect(staged).toBeGreaterThan(-1);
    expect(prettier).toBeGreaterThan(-1);
    expect(checkCall).toBeGreaterThan(staged);
    expect(commit).toBeGreaterThan(checkCall);
  });

  it('checks only the formattable staged files, not the whole tree', () => {
    expect(script).toContain('prettier --check ${formattable}');
    expect(script).toContain('/\\.(m?js|json|md|ts)$/');
  });

  it('skips the check when nothing formattable is staged', () => {
    expect(script).toContain('formattable.length > 0');
  });
});

describe('version-and-commit.mjs push failure reporting', () => {
  // $ now rejects on non-zero (errexit), so a push that never landed reaches
  // the catch as a rejection and must say which version failed to land.
  it('reports the version when the push helper exits non-zero', () => {
    expect(script).toContain('Failed to push version');
    expect(script).not.toContain('resolves (it does not throw)');
    expect(script).not.toContain('pushResult.code');
  });
});

describe('loadCommandStream shell semantics', () => {
  it('enables errexit, the semantics the release scripts are written for', () => {
    expect(useModule).toContain('shell.errexit(true)');
  });
});
