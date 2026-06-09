## Summary

When `konard/box-dind` runs its nested Docker daemon, the nested daemon starts with an **empty image store**. Any `docker run <image>` issued *inside* the container therefore reports `Unable to find image '<image>' locally` and pulls a fresh, full copy from the registry — even when the **host** daemon already has that exact image. For large images (e.g. our `konard/hive-mind-dind`, multiple GB) this re-download happens on the first nested `docker run` of every fresh container.

This is the well-known Docker-in-Docker pitfall described in jpetazzo's "Using Docker-in-Docker for your CI… is it a good idea?" — the inner Docker has its own image cache and will re-download images.

Downstream report: https://github.com/link-assistant/hive-mind/issues/1879

## Reproduction

```sh
# Host already has the image:
docker pull alpine:3.20

# Start a box-dind container and wait for the nested dockerd to be ready:
docker run -d --privileged --name dind-test konard/box-dind:latest
sleep 20   # wait for dind-entrypoint.sh to bring dockerd up

# The nested daemon does NOT see the host image — it pulls a fresh copy:
docker exec dind-test docker run --rm alpine:3.20 echo hi
# => Unable to find image 'alpine:3.20' locally
#    3.20: Pulling from library/alpine ...
```

## Workaround (what downstream does today)

Seed the nested daemon from the host with `docker save | docker load`:

```sh
docker save alpine:3.20 | docker exec -i dind-test docker load
docker exec dind-test docker run --rm alpine:3.20 echo hi   # now reused, no pull
```

We added a helper script that does exactly this for our deployment:
https://github.com/link-assistant/hive-mind/blob/main/scripts/preload-dind-isolation-image.mjs

## Suggested fix / enhancement

Make image reuse a first-class, documented capability of `box-dind` so consumers don't each reinvent it. Options, in rough order of preference:

1. **Documented startup pre-load hook.** Support an env var (e.g. `DIND_PRELOAD_IMAGES` and/or `DIND_PRELOAD_TARBALL=/path/to/images.tar`) that `dind-entrypoint.sh` loads into the nested daemon (via `docker load`) after dockerd is ready. This lets an operator bake or mount a tarball and have it auto-loaded.
2. **Optional host-image passthrough.** Document a supported pattern for sharing the host image store / socket when isolation between inner and outer daemon is not required (with the security caveats spelled out), so reuse is free.
3. **Docs.** At minimum, add a "the nested daemon starts empty; here is how to reuse host images (`docker save | docker load`, or a local registry mirror)" section to the README, since this surprises every new consumer.

Happy to send a PR for option 1 (entrypoint pre-load hook) if that direction is acceptable.

