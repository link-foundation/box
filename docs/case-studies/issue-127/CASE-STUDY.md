# Case Study: Issue #127 — A healthy sample hid an incomplete GHCR release

## Summary

Box publishes 28 image families to GitHub Container Registry (GHCR) and mirrors
them to Docker Hub. The post-release gate checked only four families: the base,
Essentials, JS, and base Docker-in-Docker images. Because the gate passed when
at least one GHCR reference was anonymously pullable, a missing language image
such as `box-python` could not make the release run fail.

The release-note generator did know all 28 families, but kept its own list.
That made the list shown to users and the list enforced by the gate two
different release contracts.

## Root cause

The checker defaulted to this sample:

```text
box
box-essentials
box-js
box-dind
```

For each family it checked the released version and `latest` in both
registries: 16 references in total. It then failed GHCR only when none of its
eight GHCR references worked. This detected a whole-registry outage, but not a
partial publication among the other 24 families.

Meanwhile, `build-release-notes.sh` separately defined the combo and language
families and derived their Docker-in-Docker variants. Adding or removing an
image could therefore change what the project published without changing what
the gate checked.

## Resolution

`scripts/release/image-inventory.sh` is now the shared 28-family inventory.
Both release notes and the anonymous publication gate source it. Unless an
operator explicitly supplies `CHECK_SUFFIXES` for a focused diagnostic, the
gate checks every family in both registries at both the released version and
`latest`—112 current references.

GHCR is the registry of record, so any private, missing, or unanswered GHCR
reference now fails the run. The existing mirror policy is unchanged: a
missing Docker Hub mirror may warn, while a published mirror missing an
expected architecture still fails because it gives users a broken answer.

The release itself is still created before this assertion. A partial image
push therefore produces an inspectable GitHub Release and a red workflow,
rather than suppressing the release and hiding the failure.

## Regression proof

`experiments/test-issue127-release-inventory.sh` replaces the production
inventory with a two-family fixture and makes only its second GHCR family
missing. Before the fix, the checker ignored that family and exited 0. After
the fix, it probes all eight fixture references and exits 1. The same test also
proves that release notes use the injected inventory and compares the
production inventory with the language and Docker-in-Docker workflow matrices.

The existing release suites were updated to expect all 112 checks while
preserving their contracts for anonymous access, optional Docker Hub absence,
platform coverage, and explicit `CHECK_SUFFIXES` overrides.

An anonymous live check of v2.10.1 on 2026-09-13, using v2.10.0 as the same
previous-release baseline the workflow supplies, completed in 1 minute 56
seconds. It found 56/56 GHCR plus 56/56 Docker Hub references pullable with
`linux/amd64` and `linux/arm64`, comfortably inside the release job's
15-minute limit.

## Reusable rule

**A sample can prove that a registry is alive; it cannot prove that a release
is complete.** The list used to describe a release and the list used to accept
it must be the same executable inventory.
