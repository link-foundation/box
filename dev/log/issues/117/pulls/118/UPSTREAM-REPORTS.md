# Upstream reports — issue #117

Issue #117 asks for two things beyond the fix itself:

> Also please add this as a separate key principle to hive-mind's
> `docs/CI-CD-BEST-PRACTICES.md` […] and report issues against any template with
> the same defect.

The defect being reported is the one this pull request fixes: **a release
pipeline that spends its build minutes before it knows whether it can publish**,
and that treats a non-empty secret as a working credential. The rule taken from
[the #115 upstream reports](../../../115/pulls/116/UPSTREAM-REPORTS.md) applies
here too — a candidate is reproduced against a clean upstream checkout before a
decision is taken, and a template that does *not* have the defect is recorded
here with the evidence rather than filed against.

## Filed

| Upstream | Report | What it has |
| --- | --- | --- |
| `link-assistant/hive-mind` | [#2221](https://github.com/link-assistant/hive-mind/issues/2221) — CI/CD principle: prove the release can be published before building it | The full draft of principle **#16, "Prove You Can Publish Before You Build"**, for `docs/CI-CD-BEST-PRACTICES.md` (which ends at #15), the two registry measurement tables, and hive-mind's own instance of the defect with line numbers |
| `link-foundation/js-…-template` | [#176](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/176) | `DOCKERHUB_TOKEN` first exercised *after* the npm publish; `check-docker-publish.mjs` tests the secret for emptiness |
| `link-foundation/rust-…-template` | [#163](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/163) | `CARGO_REGISTRY_TOKEN` and `DOCKERHUB_TOKEN`, both first exercised after the full cross-compilation matrix; no credential check of any kind |
| `link-foundation/python-…-template` | [#74](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/74) | A missing `DOCKERHUB_TOKEN` produces `enabled=false`, a `::notice::`, and a **green run that publishes no image** — the exact shape of this issue |
| `link-foundation/csharp-…-template` | [#51](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/51) | A step named `Validate NuGet API key` whose comment promises to catch an expired key and whose body tests `-z` and prints the length; and a `Create GitHub Release` that is not gated on whether the publish happened |

Each template report carries that template's own line numbers, anchored to the
commit it was read at, plus the trusted-publishing option available to it —
[`rust-lang/crates-io-auth-action@v1`](https://github.com/rust-lang/crates-io-auth-action)
for crates.io and [`NuGet/login@v1`](https://learn.microsoft.com/en-us/nuget/nuget-org/trusted-publishing)
for NuGet.org, both of which remove the expiry class of failure outright. This
follows the maintainer's preference recorded in the issue:

> we should prefer trusted publishing, where no regular tokens update is
> necessary if possible.

The csharp report is the one worth reading first. Its `Validate NuGet API key`
step has exactly the right intent and does not implement it, which is a cleaner
statement of this issue than box's own history is.

## Not filed, with the evidence

Three of the seven templates were checked and found **not** to have the defect.
`secrets.` usage across each release workflow, at the commit checked:

```
$ grep -o "secrets\.[A-Z_]*" .github/workflows/release.yml | sort | uniq -c
go     548a796:   6 secrets.GITHUB_TOKEN
java   450a10e:   1 secrets.CODECOV_TOKEN
                 13 secrets.GITHUB_TOKEN
php    5c3c906:   5 secrets.GITHUB_TOKEN
```

* **go** — publishes by pushing a tag; `proxy.golang.org` fetches it. There is no
  publishing credential to expire.
* **java** — builds with Maven and uploads the jars as GitHub Release assets
  (`gh release upload`, lines 288, 347, 403). The only non-`GITHUB_TOKEN` secret
  is `CODECOV_TOKEN` in the coverage step (line 153), which is not a publishing
  credential and already carries `fail_ci_if_error: false`.
* **php** — publishes to Packagist by webhook; the `composer` matches in an
  earlier grep were false positives for `secrets.`.

`GITHUB_TOKEN` is minted per run and cannot expire, so a pipeline that publishes
with it alone cannot fail in the way this issue describes. Filing against these
three would have been a false positive of exactly the kind [#115](https://github.com/link-foundation/box/issues/115)
was about.

## The one thing no report can fix from the outside

Both GHCR packages this repository publishes are private (confirmed by the
preflight's own report on
[run 34053764507](preflight-report-mode-run-34053764507.log): `private | HTTP 401`
for `box:latest` and `box-dind:latest`). GitHub's packages REST API is
`GET`/`DELETE`/restore only — **no endpoint changes package visibility** — so
this is a manual step in the package settings UI, documented in
[`docs/RELEASING.md`](../../../../../../docs/RELEASING.md). The pipeline's
contribution is that it now reports the state on every run instead of leaving it
to be discovered by a user whose `docker pull` fails.
