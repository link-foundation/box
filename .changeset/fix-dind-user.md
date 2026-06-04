---
bump: patch
---

Fix dind-box images so `docker exec` opens as the `box` user while the dind entrypoint still starts dockerd through scoped passwordless sudo.
