# Prior art — existing components and libraries

Answers the instruction to *"check online for known existing components/libraries
that solve a similar problem or can help"*. Grouped by the root cause each one
addresses, with a verdict on whether this repository should adopt it.

---

## For RC-1 — parent variables inside a quoted heredoc

**There is no off-the-shelf tool for this.** Verified in two ways.

1. **ShellCheck does not model it.** Its heredoc-related check, [SC2087](https://www.shellcheck.net/wiki/SC2087),
   fires on the *opposite* mistake (an unquoted heredoc piped to `ssh`, where
   expansion happens on the wrong side). There is no check for "a quoted
   heredoc references a name that only exists in the parent". ShellCheck also
   [does not analyse heredoc bodies as scripts](https://github.com/koalaman/shellcheck/issues/108).
2. **SC2154 cannot reach it even in principle.** In RC-1's shape the variable
   *is* assigned - in the parent - so "referenced but not assigned" does not
   describe it, and the heredoc body is never analysed as a script. On top of
   that, SC2154 exempts all-uppercase names by default, and every variable in
   RC-1 is uppercase. Reproduced against ShellCheck 0.11.0:

   ```bash
   $ printf 'set -u\necho "$FOO_BAR"\necho "$foo_bar"\n' > /tmp/t2.sh
   $ shellcheck -s bash /tmp/t2.sh
   In /tmp/t2.sh line 3:
   echo "$foo_bar"
          ^-- SC2154 (warning): foo_bar is referenced but not assigned.
   ```

   `FOO_BAR` produces no finding under the default options; it is reported only
   with the optional `check-unassigned-uppercase` (`-o all`), which still would
   not fire for RC-1 because the name is assigned.

**Adjacent tools evaluated and rejected for this purpose:**

| Tool | Why it does not solve RC-1 |
| --- | --- |
| `bash -n` | Syntax only; an unbound variable is a runtime condition |
| `shfmt` | Formatter |
| `bashate`, `checkbashisms` | Style / portability |
| `shellcheck -x` | Follows `source`d files, not generated ones |

**Conclusion: write the check.** The extraction is mechanical — find
`cat > FILE << 'DELIM'`, take the body, collect `${NAME}`/`$NAME` references,
and assert each is either assigned inside the body, a shell built-in, or
explicitly declared as an intended injection. Two upstream feature requests are
worth filing off the back of it (see [`SOLUTION-PLAN.md`](SOLUTION-PLAN.md#s7)).

A related, *simpler* engineering answer that removes the class of bug entirely:
**stop generating the script by heredoc**. Ship the inner script as a real file
and pass the versions as arguments or exported environment variables. Then
ShellCheck lints it directly and there is nothing left to get wrong.

---

## For RC-3 — one buildx solve pushing to two registries

**The pattern is a known buildx property, not a bug.** `--push` performs a
single solve whose export step fans out to every `--tag`; if any destination
rejects the push, the solve fails and everything it was doing — including
`cache-to` — is torn down. Related upstream reports:
[docker/buildx#663](https://github.com/docker/buildx/issues/663) (a single
tag-mutation rejection failing the push),
[docker/buildx#799](https://github.com/docker/buildx/issues/799) and
[docker/setup-buildx-action#116](https://github.com/docker/setup-buildx-action/issues/116)
(multi-tag push behaviour). The community answer, and the one the distribution
spec supports, is **push by digest per registry**.

| Component | Fit |
| --- | --- |
| **The template's own `.github/actions/publish-dockerhub`** | **Best fit.** Already in the sibling repository, already uses `outputs: type=image,…,push-by-digest=true,name-canonical=true,push=true`, one registry per invocation. Adapting it is reuse, which is exactly what [R5](REQUIREMENTS.md#r5) asks for |
| `docker/build-push-action` invoked twice (once per registry) with a shared `cache-from`/`cache-to` scope | Simplest possible change; the second solve is a cache hit, so the cost is a push, not a rebuild |
| `docker/metadata-action` | Generates the tag list per registry instead of hand-writing four tags ten times |
| [`regclient/regctl`](https://github.com/regclient/regclient), [`google/go-containerregistry` `crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane), [`skopeo`](https://github.com/containers/skopeo) | Registry-to-registry copy without a daemon. `crane copy ghcr.io/… docker.io/…` would let box publish to GHCR once and mirror afterwards, so a Docker Hub outage can never fail a build |

---

## For RC-4 — publishing without asserting the artifact exists

Hive-mind principle #13 asks for exactly this ("assert published manifests").
Daemonless one-liners, any of which can be a workflow step:

```bash
crane manifest "$IMAGE:$TAG"            > /dev/null   # google/go-containerregistry
regctl manifest head "$IMAGE:$TAG"                    # regclient/regclient
skopeo inspect --raw "docker://$IMAGE:$TAG" > /dev/null
```

`crane` is the lightest (single static binary, no config) and is the
recommendation. Placing that assertion between the manifest jobs and the dind
jobs converts RC-4's 28 misleading failures into one accurate one.

---

## For RC-5 — retrying a non-retryable error

**The template already contains the component.**
`scripts/publish-failure-classifier.mjs` and `scripts/push-failure-classifier.mjs`
implement precisely this idea for npm:

```js
export const NON_RETRYABLE_PATTERNS = [
  'npm error 404', 'npm error 401', 'npm error 403',
  'e404', 'e401', 'e403',
  'access token expired', 'eneedauth', 'you must be logged in',
  'unable to authenticate',
];
```

Box needs the registry equivalent — `unauthorized`, `denied`,
`personal access token is expired`, `failed to fetch oauth token`,
`insufficient_scope` — and it needs it in **one** place, not in ten copied
inline loops. `scripts/release/docker-push-with-retry.sh` already exists as the
natural home and is currently dead code.

---

## For RC-6 / RC-9 — linting the pipeline itself

| Tool | What it catches here | Adopt |
| --- | --- | --- |
| [`rhysd/actionlint`](https://github.com/rhysd/actionlint) | The 83 findings in the baseline. Note the **Docker image bundles ShellCheck**; a bare binary silently skips every `run:` block and exits 0 | **Yes** — `docker://rhysd/actionlint:1.7.7`, as the template does |
| [`zizmor`](https://docs.zizmor.sh) | 173 findings: `unpinned-uses` on `jlumbroso/free-disk-space@main`, `template-injection` on `${{ }}` interpolated into `run:` blocks, `excessive-permissions` | **Yes** — `zizmorcore/zizmor-action`, plus `.github/zizmor.yml` pinning policy |
| [`koalaman/shellcheck`](https://github.com/koalaman/shellcheck) | 15 findings across 64 shell scripts. Given the repository is 80.9 % shell, its absence is the single largest coverage gap | **Yes** — and this repository needs it more than the template does |
| `shfmt` | Formatting for the same 64 scripts | Yes, `--diff` mode |
| [CodeQL `actions` language](https://github.blog/changelog/2024-09-05-codeql-supports-github-actions-workflows/) | Workflow-injection and untrusted-checkout patterns actionlint does not model | Yes, via `security.yml` |
| [`actions/dependency-review-action`](https://github.com/actions/dependency-review-action) | Dependency changes introduced by a pull request | Yes |
| [`lycheeverse/lychee-action`](https://github.com/lycheeverse/lychee-action) | Dead links in README/docs | Yes |
| [`secretlint`](https://github.com/secretlint/secretlint) | Committed credentials — pointed given RC-3 is a credential problem | Yes |
| [`jscpd`](https://github.com/kucherenko/jscpd) | The ten copy-pasted retry blocks | Yes |
| `pre-commit` / `husky` + `lint-staged` | Runs all of the above before the push | Yes |

---

## For RC-7 — `always()` versus `!cancelled()`

This is documented GitHub behaviour, not a subtlety: a job whose condition is
`always()` **cannot be cancelled**. GitHub's own
[workflow cancellation reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)
and the long-running
[community discussion #25789](https://github.com/orgs/community/discussions/25789)
both land on `!cancelled()` as the correct expression for "run even if an
upstream job failed". `always()` is only right when the job must survive a
user-initiated cancel — for example a cleanup step. All 24 uses in
`release.yml` are the former case, and they actively fight the supersede
machinery added for issue #112.

---

## For RC-8 — file size

The template's `scripts/check-file-line-limits.sh` already enforces the
1500-line limit **and names `.github/workflows/release.yml` explicitly**, with a
1350-line warning threshold and GitHub `::error file=` annotations. It is
directly reusable; box needs only to extend the walked extensions to `.sh` and
`.yml`.

---

## Sources

- [docker/buildx#663 — buildx push fails when repository blocks tag mutations](https://github.com/docker/buildx/issues/663)
- [docker/buildx#799 — multiple tags using -t --tag not working](https://github.com/docker/buildx/issues/799)
- [docker/setup-buildx-action#116 — "tag does not exist" with multiple tags](https://github.com/docker/setup-buildx-action/issues/116)
- [ShellCheck SC2087](https://www.shellcheck.net/wiki/SC2087) and [SC2016](https://www.shellcheck.net/wiki/SC2016)
- [koalaman/shellcheck#108 — heredocs are parsed incorrectly](https://github.com/koalaman/shellcheck/issues/108)
- [GitHub Docs — Workflow cancellation reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)
- [GitHub community discussion #25789 — `always()` makes a job non-cancellable](https://github.com/orgs/community/discussions/25789)
- [Skopeo vs Crane vs Regctl](https://alexandre-vazquez.com/skopeo-crane-regctl-container-image-tools/)
- [google/go-containerregistry — `crane`](https://github.com/google/go-containerregistry/tree/main/cmd/crane)
