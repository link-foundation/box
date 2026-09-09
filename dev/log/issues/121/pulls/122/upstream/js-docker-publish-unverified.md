# js template: `docker-publish` never reads back what the tag it just wrote serves

**Repository:** `link-foundation/js-ai-driven-development-pipeline-template`
**File:** `.github/workflows/release.yml`, job `docker-publish`
**Compared at:** `c3a6d23b693972a70097430f01e69fcee5a51ad2`

## The asymmetry that found it

The python template's `docker-publish` ends with this
(`release.yml:979-987`):

```yaml
      - name: Verify multi-architecture manifest
        env:
          IMAGE: ${{ needs.docker-publish-config.outputs.image }}
          VERSION: ${{ needs.docker-publish-config.outputs.version }}
        run: |
          MANIFEST=$(docker buildx imagetools inspect "${IMAGE}:${VERSION}")
          grep -q "linux/amd64" <<< "$MANIFEST"
          grep -q "linux/arm64" <<< "$MANIFEST"
```

The js template's `docker-publish` is the same job, assembled by the same
`docker buildx imagetools create` call from the same digest artifacts, and has
no verification step at all. Its last action is the write.

Two sibling templates disagreeing about whether to check a publish is better
evidence of an oversight than any argument about it, and the fix is already
written in one of them.

## Why "the job was green" is not "the index is multi-arch"

`docker-publish-build` is a two-leg matrix (`linux/amd64` on `ubuntu-latest`,
`linux/arm64` on `ubuntu-24.04-arm`). Each leg writes an empty file *named after
its own digest*:

```yaml
      - name: Export image digest
        run: |
          mkdir -p /tmp/digests
          touch "/tmp/digests/${DIGEST#sha256:}"
```

`docker-publish` then collects them with `pattern: docker-digest-*` and
`merge-multiple: true`, and turns whatever is in the directory into the source
list:

```yaml
          mapfile -t digests < <(printf "${IMAGE}@sha256:%s\n" *)
          docker buildx imagetools create \
            --tag "${IMAGE}:latest" \
            --tag "${IMAGE}:${VERSION}" \
            "${digests[@]}"
```

Nothing between the matrix and the `create` compares the number of sources to
the number of legs. Two consequences follow from the artifacts being
content-named and merged into one directory:

1. **Two legs that produce the same digest collapse into one file.** Same name,
   one survives the merge. `imagetools create` is then handed a single source,
   succeeds, and publishes a single-platform index under `:latest` and
   `:${VERSION}` with every job green.
2. **`imagetools create` never fails for building less than you meant.** It
   wraps whatever sources it is given. "It resolves" is not "it was published",
   and `docker manifest inspect` answering `200` for an amd64-only index is
   exactly how this goes unnoticed.

`tests/docker-publish.test.js:118-120` asserts the *declaration*:

```js
    expect(buildJob).toContain('platform: linux/amd64');
    expect(buildJob).toContain('platform: linux/arm64');
```

That is a test of the workflow file, not of the artefact. It passes in every run
where the published index is single-platform, because the matrix still says two.

## Honest limits of this report

I did not observe this firing in the template. I am reporting a missing
verification with a stated reachability path, not a reproduced outage. What I
did reproduce is the same class one repository over: in `link-foundation/box`,
`konard/box:latest` — the tag the README hands to every reader, multi-arch since
June — was published amd64-only by a run that concluded `success`, and
`docker manifest inspect` kept answering `200` for a month. The write-up is
[box#119](https://github.com/link-foundation/box/issues/119).

## Suggested fix

The python template's step, as-is, is enough to close it. Two refinements worth
considering, both learned from box#119:

- **Check the source count against the matrix**, in `docker-publish`, before the
  `create`. It is the cheaper half of the same question and it names the cause
  rather than the symptom.
- **Verify `:latest` too, not only `:${VERSION}`.** Here they are written by one
  `create` call so they cannot diverge — but `latest` is the reference users
  actually pull, and a check that covers it stays correct if the tags are ever
  written separately.

An `unreadable platform list` should be its own outcome, distinct from "one
architecture". Treating "I could not look" as "I looked and it was wrong" costs
a release for a registry blip; box#117 was that mistake pointed the other way.
