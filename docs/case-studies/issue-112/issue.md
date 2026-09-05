## Summary

Images derived from `konard/box` / `konard/box-dind` inherit runtimes that are **older than the workloads that run in them**, and in one case two copies of the same toolchain where the one with the "current" name is the older one. Measured on `konard/hive-mind-dind:2.15.1` (base `konard/box-dind:2.4.0`) while investigating link-assistant/hive-mind#2187; the maintainer asked that the duplication be reported here so the base images stop shipping it.

## Evidence

### 1. Node.js is pinned to 20, and 20 is also the nvm `default` alias

`ubuntu/24.04/js/install.sh`:

```bash
if ! nvm ls 20 2>/dev/null | grep -q 'v20'; then
  log_info "Installing Node.js 20..."
  nvm install 20
  log_success "Node.js 20 installed"
...
nvm use 20
```

So every derived image gets `node v20.20.2` — and because `nvm install 20` is the first install, `~/.nvm/alias/default` is `20` too, which is what `~/.bashrc` activates in every shell.

Current Node.js LTS is **24.20.0** (`v26.8.1` is Current). Node 20 left Active LTS long ago. Consequences we measured downstream:

```
image:  node v20.20.2,  bun 1.3.14
task:   /tmp/issue-1069-node22/... v22.23.2   233 MB
        /tmp/issue-1069-bun-1.4.0/... 1.4.0   113 MB
```

Every task whose repository needs a newer runtime downloads its own into `/tmp` and leaves the copy behind, so the disk accumulates runtime copies on top of the stale one the image already carries.

By contrast `ubuntu/24.04/python/install.sh` already does the right thing:

```bash
LATEST_PYTHON=$(pyenv install --list | grep -E '^\s*[0-9]+\.[0-9]+\.[0-9]+$' | tail -1 | tr -d '[:space:]')
```

Node is the outlier.

### 2. `~/.rustup` carries two toolchains and `stable` is the *older* one

```
697M  ~/.rustup/toolchains/1.98.0-x86_64-unknown-linux-gnu   → rustc 1.98.0 (2026-08-18)
1.5G  ~/.rustup/toolchains/stable-x86_64-unknown-linux-gnu   → rustc 1.96.0 (2026-05-25)
```

2.2 GB for one language, and anything resolving `+stable` or a bare `cargo` silently gets **1.96.0** — two minor versions behind the pinned toolchain sitting right next to it.

Root cause looks structural rather than accidental: `ubuntu/24.04/rust/install.sh` runs `rustup-init` once, and the full image then copies the result from a cached stage:

```dockerfile
ARG RUST_IMAGE=konard/box-rust:latest
FROM ${RUST_IMAGE} AS rust-stage
...
COPY --from=rust-stage --chown=box:box /home/box/.cargo  /home/box/.cargo
COPY --from=rust-stage --chown=box:box /home/box/.rustup /home/box/.rustup
```

`stable` is therefore a **frozen snapshot of whatever stable was when `konard/box-rust` was last rebuilt**, and it keeps aging as long as that stage cache is reused, even though the full image itself is rebuilt. The second toolchain arrives later (a `rust-toolchain.toml` in a workload, or an explicit pin), at which point the image holds two toolchains whose names actively mislead.

Note that deleting a duplicate downstream does not help: a `rm -rf` in a derived layer only writes a whiteout — the bytes stay in the base layer. It has to be fixed where the layer is created, which is why this is filed here.

## Suggested fixes

1. **Track Node forward.** Either install the current LTS (resolve it at build time the way `python/install.sh` resolves the latest Python), or make the version an `ARG`/env knob (`NODE_VERSION=24`) that is bumped with each release rather than hardcoded to `20` in the script body. Whatever is chosen, set `nvm alias default` to it so shells and the PATH agree.
2. **Refresh `stable` when the full image is built**, e.g. `rustup update stable` (or `rustup toolchain uninstall stable` if the intent is a pinned toolchain only) in the same layer that materialises `~/.rustup`, so `stable` in a freshly published image is genuinely current instead of a cached snapshot.
3. **Keep one version per language root** as an image invariant: `~/.nvm/versions/node`, `~/.rustup/toolchains`, `~/.pyenv/versions`, `~/.sdkman/candidates/*`. A build-time assertion (fail if a root holds more than one version, unless the extra one is explicitly declared) would make a future regression visible at build time rather than as disk pressure months later on a deploy host.

## Downstream context

link-assistant/hive-mind#2187 tracks the same accumulation from the consumer side. In the meantime the hive-mind layer installs a pinned current Node.js/Bun on top of the base and prunes the superseded nvm version, but that is a workaround: it cannot reclaim the base layer's bytes, only stop the runtime being stale.
