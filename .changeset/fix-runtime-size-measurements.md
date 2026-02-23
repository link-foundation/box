---
bump: patch
---

Fix language runtime size measurements: correct size_mb rounding from floor-division (MiB) to nearest-MB rounding, use du-based measurement for Rust and Homebrew to avoid near-zero df deltas, and add missing bubblewrap component measurement.
