---
bump: minor
---

Resolve every runtime version at build time instead of hardcoding it (issue #112).

- **Node tracks LTS forward.** `js/install.sh` resolved the current LTS major from
  nodejs.org's release feed instead of `nvm install 20`, sets it as the nvm
  `default` alias (so a login shell runs the same Node the image installed) and
  uninstalls any other Node in the tree. The nvm installer tag is resolved too.
- **The full image no longer ships a stale rustup.** `~/.rustup` used to be
  `COPY --from=rust-stage`'d from a cached `box-rust` image, so `stable` was a
  months-old snapshot sitting next to a newer pinned toolchain (2.2 GB). Updating
  after the copy cannot fix it — a later delete only writes a whiteout — so the
  copy, `rustup update stable` and the prune now happen inside a single
  `RUN --mount=type=bind,from=rust-stage` layer.
- **One version per language root is a build-time invariant.**
  `assert_single_runtime_versions()` fails the build when `~/.nvm/versions/node`,
  `~/.rustup/toolchains`, `~/.pyenv/versions`, `~/.rbenv/versions` or any
  `~/.sdkman/candidates/*` holds more than one version; every install script
  prunes and asserts, and CI re-checks it on the built images.
- **Every box follows its upstream.** Java (SDKMAN LTS list), .NET (Microsoft's
  releases index intersected with the archive), PHP (unversioned Homebrew/apt
  formulas), Swift (newest release with a real ubuntu2404 build — the probe follows
  redirects, because download.swift.org answers a missing tarball with a 302 to
  its 404 page that `curl -f` would otherwise accept), Ruby (any major,
  ruby-build refreshed), Python (pyenv refreshed), R (CRAN), opam (current tag —
  the old `/releases/latest/download/opam-2.3.0-…` URL had been 404ing), Rust
  (always refreshed). All overridable via `NODE_VERSION`, `JAVA_VERSION`,
  `DOTNET_CHANNEL`, `SWIFT_VERSION`, `RUBY_VERSION`, `NVM_VERSION`,
  `OPAM_VERSION`, `PHP_BREW_FORMULA`, with pinned fallbacks when a feed is
  unreachable. The standalone `scripts/ubuntu-24-server-install.sh` and
  `scripts/measure-disk-space.sh` use the same policy.
- **Covered by tests:** `experiments/version-policy-unit-test.sh` (69 assertions),
  `experiments/rust-refresh-layer-test.sh` (measures COPY-then-delete at +256 MB
  vs single-layer at +128 MB for a 128 MB payload),
  `experiments/node-lts-integration-test.sh`, a new `pr-test / version-policy` CI
  tier that also checks the resolvers against the live feeds, and freshness
  assertions in the js and full-box smoke tests. Full rationale in
  `docs/case-studies/issue-112/`.
