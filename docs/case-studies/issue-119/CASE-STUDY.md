# Case Study: Issue #119 — The mirror published half an image, and every check said yes

## Executive Summary

v2.7.0 was the first release after issue #117 made the publication check
anonymous, and it worked: the notes reported "Docker Hub (mirror): 1 pullable
of 28", which was true. The release shipped anyway, and `konard/box:latest` —
the tag the README hands to every reader — went from serving two architectures
to serving one. An arm64 user pulling it gets `no matching manifest for
linux/arm64`.

| # | Finding | Root cause | Resolution |
|---|---------|-----------|------------|
| a | `konard/box:2.7.0` and `konard/box:latest` are amd64-only; `konard/box-dind:2.7.0` is absent. | `mirror-to-dockerhub.sh` copies with `docker buildx imagetools create`, which **always** wraps its result in an OCI index — even for one platform. `create-multiarch-manifest.sh` then called `docker manifest create`, which refuses an index as a source. Run 34056619231: `docker.io/***/box:2.7.0-amd64 is a manifest list`, three times, then a warning. | The manifest step publishes with `imagetools create`, which accepts both shapes, and Docker Hub no longer assembles anything: it mirrors the index GHCR already serves. |
| b | `konard/box:latest` was left amd64-only rather than merely stale — a regression, not a lag. | The `box` amd64 job mirrored **8** tags, the 4 suffixed *and* the 4 unsuffixed, so it claimed `:latest` for itself. `box-dind`'s mirror wrote only suffixed tags, which is why that one is simply missing. The two families disagreed about which job may write a tag a user pulls. | Only a step whose name contains "manifest" may name an unsuffixed reference; `test-issue119-tag-policy.sh` reads every image reference out of the five release workflows and asserts it. |
| c | Nothing failed the run. | `check-publication.sh` asked "does this resolve?", and an amd64-only index answers yes. `latest` was not even in the sample. | The check reads the platform list of every reference, fails on a tag that carries fewer architectures than the release built, and compares against what the previous release carried. |
| d | The notes listed `konard/box-dind:2.7.0` as not published and then linked its `2.7.0-arm64` tag, under a column headed **Multi-arch**. | The column was a heading, not a measurement. | The heading is "Tag"; the cell carries the probe's answer for that exact reference, and a per-architecture tag is linked only where the reference was measured to serve that platform. |

One sentence covers all four: **"it resolves" is not "it was published"** — and
every mechanism that could only ask the first question has been taught to ask
the second.

---

## 1. Two tools that write the same format and cannot read each other's output

`docker buildx imagetools create` and `docker manifest create` both produce a
multi-platform tag. They are not interchangeable, and the difference only
appears when one is fed the other's output:

```
ghcr.io/link-foundation/box-dind:2.7.0-amd64   application/vnd.oci.image.manifest.v1+json   (plain manifest)
docker.io/konard/box-dind:2.7.0-amd64          application/vnd.oci.image.index.v1+json      (index)
```

Both references hold the same image. The GHCR one was pushed by buildx as part
of the build; the Docker Hub one was *copied* by `imagetools create`, which
wraps whatever it copies in an index, even when there is exactly one child.
`docker manifest create` refuses an index source, so the Docker Hub manifest
step could never have worked — not on a slow day, not on a retry. From run
34056619231:

```
2026-09-07T09:31:40.5957464Z docker.io/***/box:2.7.0-amd64 is a manifest list
2026-09-07T09:31:40.5979053Z ==> ***/box:2.7.0: attempt 1 failed; retrying in 10s
… attempt 2 … attempt 3 …
2026-09-07T09:32:11.3832229Z ##[warning]Could not publish multi-arch manifest(s)
```

Three attempts and 40 seconds spent on an input that is deterministically the
wrong media type. **Retrying a deterministic failure is not a retry policy, it
is a delay** — and worse, it dresses a permanent defect in the costume of a
transient one, which is why the warning read like a flaky registry for a month.

The fix is the one the issue proposed: stop assembling a second index on Docker
Hub from mirrored per-architecture tags, and copy the index GHCR already
serves. It removes a step rather than repairing it, and the remaining
`create-multiarch-manifest.sh` publishes with `imagetools create`, which
accepts a plain manifest and an index alike.

## 2. Which job is allowed to write a tag a user pulls

The amd64 job mirrored eight tags:

```
2026-09-07T09:01:52Z pushing … to docker.io/***/box:latest
2026-09-07T09:01:53Z pushing … to docker.io/***/box:2.7.0
…
2026-09-07T09:02:02Z ==> Mirrored ghcr.io/link-foundation/box:2.7.0-amd64 to 8 Docker Hub tag(s)
```

An architecture-specific job wrote `:latest`. Even with §1 fixed there is a
window — from 09:01:52 until the manifest step at 09:31 — in which
`konard/box:latest` is amd64-only; when §1 fails, that window never closes.
Meanwhile `box-dind`'s mirror wrote only suffixed tags, which is why
`konard/box-dind:2.7.0` was absent rather than half-right. Two spellings of the
same step, disagreeing about a rule nobody had written down.

That `latest` push is what a reader gets today: on Docker Hub
`konard/box:latest` and `konard/box:2.7.0` are the same object,
`sha256:9ac67276...`, read anonymously on 2026-09-08.

It is written down now, and it is checkable without running anything: an
architecture-specific step may only name a reference ending in `-amd64` or
`-arm64`, and only a manifest step may name a bare one.
`experiments/test-issue119-tag-policy.sh` extracts every image reference from
the five release workflows along with the step it belongs to and asserts
exactly that, so the next family added to the matrix cannot quietly pick the
other convention.

For the manifest step to be the only writer, it has to know every tag the
release writes — and it did not. The full box's tags were computed
independently in each job by `docker/metadata-action`, whose
`{{date 'YYYYMMDD'}}` is evaluated *when the step runs*; the full box takes
over an hour to build, so a release started near midnight UTC hands its two
architecture jobs two different dates. The manifest job, meanwhile, knew only
about `latest` and the version, which is why the date and commit tags kept
whatever the single-architecture job had pushed:

```
ghcr.io/link-foundation/box:2.7.0     linux/amd64 linux/arm64
ghcr.io/link-foundation/box:20260907  linux/amd64
ghcr.io/link-foundation/box:fd4742b   linux/amd64
```

`scripts/release/image-tags.sh` computes that list once and hands it to the
other jobs through `IMAGE_TAGS`, so "which tags does this release write?" has
one answer per run and every one of them reaches the manifest step.

## 3. "It resolves" is not "it was published"

`check-publication.sh` was added by issue #117 and did what it was built to do:
it asked, anonymously, whether each reference could be pulled. `konard/box:2.7.0`
answered HTTP 200. It served one architecture.

Resolvability is the property a broken index shares with a correct one. So the
check now reads the platform list — free for an index, one extra request for a
plain manifest — and fails when a reference carries less than the release built.
Three distinctions hold it together:

- **An absent mirror tag is a lag; a wrong one is not.** Docker Hub is a mirror
  and may trail the registry of record, so a missing tag stays a warning
  (issue #115, RC-18). A tag that resolves and serves the wrong architecture is
  not lag: somebody pulling it today gets the wrong answer today. That fails the
  run even though `DOCKERHUB_REQUIRED=0`.
- **An empty platform list means "I could not look", never "one architecture".**
  Reporting an unmeasurable reference as broken would be issue #117's false
  claim pointed the other way — and this one costs a release.
- **A constant cannot notice what the project has stopped shipping.**
  `EXPECTED_PLATFORMS` is a constant, so `PREVIOUS_VERSION` adds the other
  comparison: a tag that was multi-arch in the previous release and is
  single-arch now is a regression, whatever the constant says. The baseline
  only counts when the previous release's reference is itself published; a
  private or missing baseline is evidence of nothing.

`latest` also joined the sample. It was the tag the regression landed on, and
the sample that excluded it is the reason nothing failed.

## 4. A column heading is not a measurement

The v2.7.0 notes listed `konard/box-dind:2.7.0` under "these references are
**not published**" and, three tables further down, linked its `2.7.0-arm64`
tag. They headed `konard/box:2.7.0` with a column called **Multi-arch** while
that reference served linux/amd64 alone.

A heading reads the same in the release where the mirror worked and in the
release where it did not. That is precisely the property that makes it useless
to a reader deciding whether to pull — the same defect as a check that cannot
fail, in documentation form. The column is "Tag" now, and the cell says what
the probe measured:

```
| Full Box | [`konard/box:2.7.0`](…) - **linux/amd64 only**, missing linux/arm64 | [`2.7.0-amd64`](…) | `2.7.0-arm64` |
| Full Box + dind | `konard/box-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
```

A Docker Hub tag-search URL renders for a tag that was never pushed, so linking
one advertises an image that is not there — RC-17's defect without the 404 that
would have given it away. A reference the probe could not pull is a bare code
span, and a per-architecture tag is linked only where its reference was
measured to serve that platform. Without `VERIFY_IMAGES` nothing was measured
and nothing is claimed; the notes say so in one line above the tables.

## 5. What now fails that used to pass

Run against the *released* v2.7.0 from this branch, with no credentials
(`dev/log/issues/119/pulls/120/check-publication-v2.7.0.log`):

```
konard/box:2.7.0     published  linux/amd64  anonymous GET of the manifest returned HTTP 200
konard/box:latest    published  linux/amd64  anonymous GET of the manifest returned HTTP 200
==> GHCR (registry of record): 8/8 pullable anonymously.
==> Docker Hub (mirror):       5/8 pullable anonymously.
::error title=The Docker Hub mirror of v2.7.0 is single-architecture::2 mirrored reference(s)
  resolve but do not carry linux/amd64 linux/arm64. … An absent mirror tag would be a warning;
  a wrong one is not.
exit=1
```

The same release, the same registries, the same anonymity — a red run instead
of a green one. The regenerated notes for v2.7.0 are alongside it in
`release-notes-v2.7.0-anonymous.md`, with `konard/box:2.7.0` marked
`**linux/amd64 only**, missing linux/arm64` and its arm64 link gone.

Offline, the four suites that pin this behaviour:

| Suite | Assertions | Pins |
|-------|-----------|------|
| `test-issue119-platform-coverage.sh` | 21 | what a reference *serves*, for an index, a manifest list and a plain manifest alike |
| `test-issue119-image-tags.sh` | 19 | one deterministic tag list per release, shared by the jobs that used to each compute their own |
| `test-issue119-check-publication.sh` | 16 | platform coverage, the previous-release comparison, and the three distinctions in §3 |
| `test-issue119-tag-policy.sh` | 13 | only a manifest step writes an unsuffixed tag, across all five workflows |
| `test-issue119-manifest-media-type.sh` | 11 | an index source is accepted, and a Docker Hub tag is mirrored rather than assembled |
| `test-issue115-release-notes.sh` | 50 | §4, down to which of the two per-architecture links survives |

## 6. The principle, stated for reuse

1. **A tag that resolves with fewer architectures than the release built is a
   failed publication, not a successful one.** "Does it exist" and "does it
   serve who it was built for" are different questions, and only the second one
   is what a user asked.
2. **Retrying a deterministic failure is a delay dressed as resilience.** If the
   input cannot ever be accepted, the retry loop converts a clear error into a
   slow warning.
3. **A tag a user pulls may only be written by the step that has all the
   architectures.** Anything else publishes a correct-looking tag that is true
   of one platform.
4. **Documentation that states a property statically states it in the release
   where it is false.** Print the measurement, or print nothing.
5. **"I could not measure it" is its own answer.** Collapsing it into either
   "fine" or "broken" invents a fact, and both directions have shipped a wrong
   release in this repository.

## 7. Still outstanding

The Docker Hub mirror of v2.7.0 stays wrong until a release runs with these
changes: nothing here rewrites a published tag. `konard/box:latest` will be
correct again with the next release, and until then the README says which
registry carries which version. GHCR — the registry of record — has been
correct throughout, including for the consumer that prompted the issue
(link-assistant/hive-mind#2187 pins `ghcr.io/link-foundation/box:2.7.0`).
