---
bump: patch
---

ci(release): make changeset application quote-safe so descriptions containing
apostrophes, such as buildx's log text, no longer abort the main release
workflow with xargs parsing errors.
