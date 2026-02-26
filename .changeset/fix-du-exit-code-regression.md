---
bump: patch
---

Fix CI failure caused by `du` exit code regression introduced in Issue #55 fix: only pass paths that exist to `du -sb` to avoid killing the script under `set -euo pipefail` when Homebrew or Rust installation dirs are absent.
