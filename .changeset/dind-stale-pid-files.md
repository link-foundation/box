---
bump: patch
---

Start the nested Docker daemon in a box resumed from a docker commit snapshot by removing dockerd and containerd pid files left by the previous container. Keep the containerd pid file while containerd is still running so live restore can reuse it.
