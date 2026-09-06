# S7 outcomes — upstream reports (R4)

[R4](REQUIREMENTS.md#r4) asks that a defect found here be reported upstream when
the same defect exists there. [`SOLUTION-PLAN.md`](SOLUTION-PLAN.md#s7) lists the
candidates; this file records what happened to each one.

The rule the plan set for itself:

> If reproduction shows a candidate does **not** affect upstream, that is
> recorded here with the evidence rather than filed — R4 asks for reports of
> *shared* defects, and a wrong report is worse than none.

Every candidate below was reproduced against a clean upstream checkout before a
decision was taken. Three were filed, two were filed against the template, one
was added as evidence to an existing upstream issue, and two were not filed
because reproduction showed the defect is ours and not theirs.

## Filed

| Upstream | Report | Root cause here |
| --- | --- | --- |
| `leanprover/elan` | [#210](https://github.com/leanprover/elan/issues/210) — `elan-init --default-toolchain` records the default but never installs it (exits 0 with no toolchain on disk) | [RC-14](ROOT-CAUSES.md#rc-14) |
| `secretlint/secretlint` | [#1688](https://github.com/secretlint/secretlint/issues/1688) — an empty `"rules": []` scans and exits 0 silently, while the three neighbouring misconfigurations all exit 2 | [RC-16](ROOT-CAUSES.md#rc-16) |
| `koalaman/shellcheck` | [#3534](https://github.com/koalaman/shellcheck/issues/3534) — warn when a *quoted* heredoc references a variable of the enclosing script (the mirror image of SC2087) | [RC-1](ROOT-CAUSES.md#rc-1) |
| `link-foundation/js-ai-driven-development-pipeline-template` | [#174](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/174) — `check-file-line-limits.sh` walks `find`, not the tracked file list | [RC-8](ROOT-CAUSES.md#rc-8), [RC-16](ROOT-CAUSES.md#rc-16) |
| `link-foundation/js-ai-driven-development-pipeline-template` | [#175](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/175) — `pipeline-status.needs` is a hand-maintained copy of the job list | [RC-10](ROOT-CAUSES.md#rc-10) |
| `link-foundation/js-ai-driven-development-pipeline-template` | [#167 comment](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/167#issuecomment-5556797713) — the mirror side of an existing issue: on a pull request, a job killed by `timeout-minutes` produces a green Pipeline Status | [RC-4](ROOT-CAUSES.md#rc-4), [RC-7](ROOT-CAUSES.md#rc-7) |

### elan #210

`elan-init --default-toolchain stable` prints `info: default toolchain set to
'stable'` and exits 0. `~/.elan/toolchains` does not exist afterwards, and
`~/.elan/bin/lean` is a shim that downloads on first use — so `lean --version`
in a `RUN` step passes against an image that contains no Lean. Reproduced live
on elan 4.2.4 (`227caca13`):

```
info: default toolchain set to 'stable'
installer exit: 0
--- elan toolchain list ---
no installed toolchains
--- ls ~/.elan/toolchains ---
ls: cannot access '/root/.elan/toolchains': No such file or directory
--- elan show ---
leanprover/lean4:v4.33.1 (resolved from default 'stable')
(toolchain will be installed on first use)
```

The report suggests calling `install_from_dist_if_not_installed()` from
`setup_mode`, plus three softer alternatives (a warning, a `--no-install` opt-out,
a documentation change). Our own fix does not wait for it:
`test -d ~/.elan/toolchains/*` is the assertion, because a shim cannot satisfy it.

### secretlint #1688

`"rules": []` is accepted, scans every file, finds nothing and exits 0. The three
adjacent misconfigurations are all rejected with exit 2 — `rule` instead of
`rules`, a nonexistent rule id, and a malformed descriptor — so the silent one is
the odd case, not the rule. Reproduced on Node 22.23.2 / secretlint 13.0.5 with a
planted AWS key that the correct configuration detects:

```
--- correct preset (control) ---
  2:0  error  [AWSSecretAccessKey] found AWS Secret Access Key  …
exit=1
--- empty rules array ---
exit=0
--- typo: rule instead of rules ---
Error: secretlintrc should have required 'rules' property.
exit=2
--- nonexistent rule id ---
Error: Failed to load secretlint's rule module: … is not found.
exit=2
```

Suggested fix: a `rules.length === 0` guard in `validateConfigDescriptor`
(`@secretlint/config-loader`), beside the existing `Array.isArray` check.

### shellcheck #3534

SC2087 warns when an *unquoted* heredoc sent to `ssh` interpolates a local
variable. Nothing warns about the mirror case: a *quoted* heredoc whose body
references a name that exists only in the enclosing script, where the reference
expands to the empty string in the child. That is [RC-1](ROOT-CAUSES.md) — the
generated `measure-disk-space` script ran with every threshold empty. The report
carries both reproducers, the SC2034 precedent (the information is already in the
AST), and a four-condition rule to keep the false-positive rate at zero.

### Template #174 and #175

Both are the false-negative shape this whole pull request is about, found in the
template that [R3](REQUIREMENTS.md#r3) names as the reference:

- **#174** — `check-file-line-limits.sh` says it "walks every tracked JavaScript
  and Markdown file" and uses `find .` instead. Four reproductions: a TypeScript
  project generated from the template has all 7000 lines of its sources unchecked
  and the job prints *"All checked files are within the 1500 line limit!"*; a
  `release.yml` renamed to `.yaml` is skipped with a `WARNING:` inside a green
  step; an empty tree passes vacuously; and a git-ignored `dist/bundle.js` fails
  the gate with a hint nobody can act on. Our port
  (`scripts/ci/check-file-line-limits.sh`) enumerates with `git ls-files`, covers
  `yml|yaml` so no file needs a special case, and exits 2 when `CHECKED` is 0.
- **#175** — `pipeline-status.needs` lists all 15 other jobs in `release.yml` by
  hand. The list is complete as shipped; nothing keeps it complete. Deleting one
  line passes actionlint, and `check-pipeline-status.sh` then prints *"All
  required jobs succeeded or were legitimately skipped."* for a run in which that
  job failed, because `toJSON(needs)` simply does not contain it. The report ships
  a working checker that compares the job keys against the gate's `needs`.

### Template #167 — comment rather than a new issue

The existing issue covers a false *error* on `main`; the evidence added covers the
false *pass* on a pull request, which is the same `IS_MAIN` branch read the other
way. `release.yml` declares `timeout-minutes` 22 times and
`run-with-budget-warning.sh` wraps 7 steps, so the mitigation the code comment
offers ("a genuine overrun should surface as a step budget failure instead") does
not cover most of the pipeline — and the wrapper has its own hole (their #164).

## Not filed, with the evidence

| Candidate | Why not |
| --- | --- |
| `mvdan/sh` — associative-array subscripts | Already reported three times upstream and closed each time |
| `rhysd/actionlint` — heredocs in `run:` blocks | Reproduction shows actionlint faithfully reports what its bundled shellcheck finds; the blind spot is shellcheck's, and is #3534 |
| `secretlint/secretlint` — a missed AWS key | Not reproducible; the apparent miss was a quoting artefact in my own test harness |
| Template — `simulate-fresh-merge.sh` | The differences are hardening in our port, not a live defect there |

### mvdan/sh

`shfmt` rewrites `[node-lts-integration-test.sh]=1` to
`[node - lts - integration - test.sh]=1` — a different key, silently, which is how
the skip list of the runner that runs every check was disabled
([RC-21](ROOT-CAUSES.md)). Upstream has declined this three times —
[#1343](https://github.com/mvdan/sh/issues/1343),
[#1273](https://github.com/mvdan/sh/issues/1273),
[#1367](https://github.com/mvdan/sh/issues/1367) — each closed pointing at the
README caveat *"when indexing Bash associative arrays, always use quotes"*,
because the static parser cannot tell a literal key from arithmetic. A fourth
report would add nothing. The invariant that keeps it from recurring here is that
no subscript is left unquoted, asserted by
`experiments/test-issue115-shfmt-gate.sh`.

### rhysd/actionlint

actionlint 1.7.7 bundles shellcheck 0.10.0 and surfaces its findings against
`run:` blocks — verified with a fixture whose `run:` block has an unused
variable:

```
t.yml:8:9: shellcheck reported issue in this script: SC2034:warning:1:1: NODE_MAJOR appears unused …
```

So a heredoc check added to shellcheck reaches actionlint for free, and asking
actionlint to implement it separately would duplicate #3534.

### secretlint — the AWS rule is not the problem

One `docker run` during the RC-16 investigation showed the *control* case exiting
0, which would have been a much more serious upstream defect than the empty-rules
one. It did not reproduce. `bash scripts/ci/run-secretlint.sh` passes its canary;
a 100-sample rate test gave `files: 100 detected: 100 missed: 0`; a variant test
gave 30/30 for alphanumeric keys and 30/30 for base64 keys containing `/` and `+`.
The single exit 0 was a quoting artefact in a nested `docker run bash -c '…'` in my
harness. Nothing was filed, which is the point of running the control twice.

### Template — `simulate-fresh-merge.sh`

Our port adds shallow-clone deepening, three fetch retries and a merge-base guard
that the template's script does not have. Those are not template bugs: the
template's `release.yml` checks out with `fetch-depth: 0` at all nine call sites
(lines 64-66, 107-109, 135-137, 158-160, 212-215, 291-294, 473-475, 580-582,
802-804), so the "unrelated histories misreported as a merge conflict" failure
cannot occur there. The retry gap *is* a real template defect, and it is already
filed upstream as
[#169](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/169).

## Not a defect: the template's secretlint configuration

Worth recording because it is the closest the template comes to
[RC-16](ROOT-CAUSES.md). `.secretlintrc.json` there names the preset correctly:

```json
{ "rules": [ { "id": "@secretlint/secretlint-rule-preset-recommend" } ] }
```

so the empty-rules trap in secretlint #1688 does not apply to it. The template's
scan has no canary, so its silence is still unverified — but that is a hardening
suggestion, not a shared defect, and R4 asks for the latter.
