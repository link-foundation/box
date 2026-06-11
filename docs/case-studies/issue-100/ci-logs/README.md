# CI evidence — run 27314587149 (issue #100)

The full raw job logs are `*.log` in this directory but are **git-ignored**
(repo-wide `*.log` rule) because they are large and ANSI-laden. To re-download
them:

```bash
for id in 80693193608 80694639183 80694639277 80694639315; do
  gh run view --repo link-foundation/box --log --job "$id" \
    > docs/case-studies/issue-100/ci-logs/job-$id.log
done
```

Run: <https://github.com/link-foundation/box/actions/runs/27314587149>
(push of merge commit `57abb41`, 2026-06-11 00:06:44 UTC).

## Decisive excerpts

### 1. Root cause — `build-languages-amd64 (java)` ([job 80693193608](https://github.com/link-foundation/box/actions/runs/27314587149/job/80693193608))

`setup-buildx-resilient` pre-pull exhausts all 5 retries against Docker Hub:

```
00:16:25 ==> Pulling moby/buildkit:buildx-stable-1 (attempt 1/5)...
00:16:40 Error response from daemon: Get "https://registry-1.docker.io/v2/": net/http: request canceled while waiting for connection (Client.Timeout exceeded while awaiting headers)
00:16:40 ==> Pull failed, waiting 5s before next attempt...
... attempts 2/5 .. 5/5, backoff 10s/20s/40s, same timeout ...
00:18:55 ==> WARNING: could not pre-pull moby/buildkit:buildx-stable-1 after 5 attempts; letting setup-buildx try its own boot pull
```

Then the buildx boot's own pull fails the same way and fails the job:

```
00:18:58 ##[group]Creating a new builder instance
00:19:13 #1 ERROR: Error response from daemon: Get "https://registry-1.docker.io/v2/": net/http: request canceled while waiting for connection (Client.Timeout exceeded while awaiting headers)
00:19:13 ##[error]ERROR: ... registry-1.docker.io ... Client.Timeout exceeded ...
```

### 2. Cascade — `build-dind-amd64 (java)` ([job 80694639277](https://github.com/link-foundation/box/actions/runs/27314587149/job/80694639277))

The java amd64 base image was never pushed, so the dependent dind build cannot resolve it:

```
#3 ERROR: docker.io/***/box-java:2.3.0-amd64: not found
ERROR: failed to build: failed to solve: ***/box-java:2.3.0-amd64: failed to resolve source metadata ... not found
##[error]Process completed with exit code 1.
```

### 3. Cascade — `build-dind-amd64 (full)` ([job 80694639315](https://github.com/link-foundation/box/actions/runs/27314587149/job/80694639315))

`docker-build-push` was skipped (it requires `build-languages-amd64` success), so the full `box` amd64 image was never built:

```
#3 ERROR: docker.io/***/box:2.3.0-amd64: not found
ERROR: failed to build: failed to solve: ***/box:2.3.0-amd64: ... not found
```

### 4. Cascade — `build-dind-arm64 (full)` ([job 80694639183](https://github.com/link-foundation/box/actions/runs/27314587149/job/80694639183))

Same skip chain (`docker-build-push-arm64` needs `docker-build-push`):

```
#2 ERROR: docker.io/***/box:2.3.0-arm64: not found
ERROR: failed to build: failed to solve: ***/box:2.3.0-arm64: ... not found
```

## Why arm64 language builds were green

Every arm64 language build and every other amd64 language build succeeded in the
same run — the outage was a narrow network blip localized to one amd64 runner
during the 00:16–00:19 window, not a code defect. See `../CASE-STUDY.md` §1.
