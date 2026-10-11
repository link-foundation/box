---
bump: patch
---

Enable live restore for the nested Docker daemon by default so its containers survive daemon restarts. Allow opting out with DIND_LIVE_RESTORE=0 and honor an existing live-restore setting in daemon.json without conflicting command-line flags.
