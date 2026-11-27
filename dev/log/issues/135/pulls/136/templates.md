# CI/CD template comparison

The full tracked trees are in [github](github/), alongside the pinned commits and fingerprints of every file under the CI, automation, and hook directories. [CI role index](github/ci-role-index.tsv) adds each root CI config and build manifest to the workflow, action, hook, release-metadata and script inventory. It groups literal paths by normalized role name. A dash means there is no matching filename role; use the functional table below for implementations with different names.

| Tree | Pinned revision | Focus |
| --- | --- | --- |
| Box | `a89c079` plus the PR | Container images, nested Docker, installation and size measurement |
| JavaScript | [8e72538](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/tree/8e72538d579d904aff818c2447fb3c2413d3a989) | Multiple JS runtimes, artifact transport, JS-first gates and npm |
| Rust | [1d29f55](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/tree/1d29f5541bce3fd47925c0b498937aee19776121) | Cargo and Clippy, cross-platform Desktop targets and crates |
| Python | [7a05d05](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/tree/7a05d0515fac2966885b272302c1055985bc948b) | uv/pytest/Ruff, docs and PyPI |
| PHP | [e12a25d](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/tree/e12a25d7ce9d8bfd37f238b1b238c0006bf52031) | Composer, static analysis, PHP format/tests and Packagist |

| Workflow and script families | Box disposition |
| --- | --- |
| Links, archive and retry | JS and Rust already have richer archive behavior. Rust's recheck uses GET and report accounting. Use matching semantics in both Box readers. PHP, Python and JS HEAD tests reproduced the false green, and PHP and Python archive tests reproduced the outage ambiguity. JS, Python and PHP archive parsers also missed URL punctuation, and Python misread successful redirects. The eight reports and offline fixtures are recorded with the evidence. |
| Workflow audit, path filtering, terminal status, superseded runs and job budgets | Box uses workflow syntax/lint, Zizmor, checkout-credential checks, path coverage, and per-job budget checks, together with a final aggregate check. JS and Rust additionally auto-rerun selected infrastructure failures. Box classifies failures in its native release, registry, and supersede helpers. A blanket rerun can delay stable failures and duplicate expensive builds. |
| Tests, examples, language gates and app builds | JS first-gate/example and Rust desktop workflows check the package template's application and architecture contracts. Box checks shipped shell/JS/Python scripts, shell format, Dockerfiles, regression experiments, runtime smoke scenarios, and its real Linux container matrix. Package-specific source, lockfile and runtime matrices target delivered package code. Box provisions several toolchains but has no product package manifest for those managers. |
| Release plumbing, credentials, state and artifact transport | Templates publish packages and some examples or desktop binaries. Box publishes native AMD64/Arm64 images and consumes digest/manifest, registry credential probes and build-chain artifacts. Changesets drive versions, the actual merge is checked, and per-registry retry helpers classify failures. Retain workflow-specific publication logic and only use archive transport for a demonstrated artifact service problem. |
| Docs, template self-consistency and file limits | PHP and Python have separate docs gates, and PHP checks multiple template surfaces. Box has required-doc and link checks and a separate file line budget. Historical logs are archived separately from active code so representation does not affect the production gates. |
| Dependabot, dependencies, secret scanning and security | Python includes a bot-health workflow. All four have security gates, with tools matching their packages. Box scans shell-dependent workflows and source with Zizmor, CodeQL and Secretlint, and validates installed image versions and pull/publish paths. Language package install and audit policies apply to template package lockfiles. Box's dependency surface consists primarily of the base image, tools installed by Dockerfiles, and external actions. A comprehensive OS/image vulnerability scan would be distinct work; current coverage verifies versions, Dockerfiles, and workflow dependencies. |
| Shell/container-specific infrastructure | Box has distinct jobs for disk reclaim, swap, budget telemetry and component size tracking. The template package workflows lack that system-wide installer. Keep its dedicated workflow, and use ordinary job prerequisites and validated artifacts to eliminate false results. |
| Development helper scripts and hook tooling | Hooks and automated changeset checks retain the same duties across implementations. Box's shell hook reuses the CI checks. Package release scripts, project scaffold helpers, development examples and build-specific binary tools were kept in their template roles. |

## Hive Mind practices

The source guidance is [the Hive Mind CI/CD document](https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md). This table records the Box checks and the specific application choices that affect verdicts.

| Practice | Application in Box |
| --- | --- |
| 1. Run relevant checks | Workflow path filters cover lint inputs, tested by `check-workflow-path-coverage.mjs`. Release's path classifier determines the affected image tiers. PR validation runs fast tests even when expensive publication is disabled, and a manual or main run can exercise the installer. |
| 2. File line limits | `file-sizes.yml` invokes `check-file-line-limits.sh` and propagates failures. |
| 3. Automated formatting | Scripts and local hooks use `run-shfmt.sh` for shipped and test shell. |
| 4. Static analysis | Scripts check heredocs, awk portability, JavaScript and Python syntax, and ShellCheck. Dockerfiles use Hadolint. Security uses CodeQL where supported. |
| 5. Fast failures | Release validates inputs before image build jobs. The disk install now requires its fast preflight, including a wrapper cleanup regression. |
| 6. Changesets | `.changeset/ci-verdicts.md` triggers an automated patch. Changeset scripts validate, coalesce and apply changes before publication. |
| 7. Check the merge result | `simulate-fresh-merge` runs relevant PR workflows against a fresh merge; use repository-controlled safe checkout behavior. |
| 8. Local hooks | `.githooks/pre-commit` and `scripts/install-git-hooks.sh` expose the same checks early. |
| 9. Automated releases | The release orchestrator prepares versions, calls native build workflows, creates multi-arch manifests and validates publication. |
| 10. Concurrency | Scoped concurrency groups and the supersede helper ensure replaced runs can stop without converting current failures into successes. Measure's slow request and PR validation use separate groups. |
| 11. Detect secrets | Security uses Secretlint and the Box experiment suite tests masking opt-in credential diagnostics. Existing checkout permission validation remains in place. |
| 12. Documentation | Dedicated Docs and Links workflows. Link recovery leaves anchors/local files to Lychee and keeps 404 and archived-only live failures red. |
| 13. Native container architectures | Release tiers use Ubuntu AMD64 and Arm64 runners, publishing combined platform manifests. |
| 14. Lint workflows | Workflow syntax, Zizmor and explicit job/status/path and permission checks validate workflow behavior. |
| 15. Audit dependency trees | Existing workflow dependency audits check actions; Box's image dependencies are installed by the platform/Dockerfiles, and the PR version and runtime scenarios verify those contracts. Template-specific npm/Cargo/uv/Composer lockfile audits require a package dependency tree. |
| 16. Preflight publishing | `preflight` verifies release credentials and relevant registry operations. PR jobs do not require write credentials; disk measurements run on the branch but can only publish from main. |
| 17. Classify the real failure | Link scan failure differs from unavailability of the scanner or archive service. Disk generation validates fresh files before output publishing. Existing terminal status, supersede and retry classifiers preserve cancellations and originating failure types. |
