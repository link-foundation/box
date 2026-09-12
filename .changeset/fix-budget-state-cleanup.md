---
bump: patch
---

Keep the CI budget wrapper's private state outside temporary directories that
the wrapped command may clean, and keep credentials out of opt-in verbose
traces.
