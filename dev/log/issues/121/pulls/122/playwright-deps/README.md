# Playwright host dependencies: the warning that could not fail a build

`playwright install` prints a "Playwright Host validation warning" naming the
system packages its browsers need, and then **exits 0**. In a `RUN` layer that
means the layer commits, the image ships, and the box hands its user browsers
that cannot start. Issue #121 calls this class of defect a false negative: the
check ran, found the problem, said so, and passed anyway.

Three builds of `ubuntu/24.04/js/Dockerfile` on this machine, 2026-09-09:

| Log | Tree | `Playwright Host validation warning` | Build |
| --- | --- | --- | --- |
| `build-before.log.gz` | `main` (e77abcc) | **1** — `sudo apt-get install libavif16` | **succeeds** (`#12 DONE 334.8s`) |
| `build-after.log.gz` | this branch | 0 | succeeds |
| `build-mutation.log.gz` | this branch, `libavif16` deleted from the Dockerfile | 1 | **fails**, exit 1 |

The mutation is the part that matters: it is the same build as `after` with the
fix's package list broken on purpose, and it shows the new assertion turning the
warning into a build failure rather than merely removing today's instance of it.

```
2435:#12 339.3 Playwright Host validation warning:
2443:#12 339.3 ║     sudo apt-get install libavif16                   ║
2454:#12 339.4 [✗] Playwright reports missing host dependencies: libavif16
2457:#12 ERROR: process "/bin/bash -o pipefail -c ... /tmp/install.sh ..." did not
     complete successfully: exit code: 1
```

The assertion is `assert_no_playwright_host_warning` in `ubuntu/24.04/common.sh`;
`JS_ALLOW_PLAYWRIGHT_HOST_WARNING=1` is the documented escape hatch, printed by
the failure itself. `experiments/test-issue121-playwright-deps.sh` covers it
offline.

Reproduce:

```bash
docker build -f ubuntu/24.04/js/Dockerfile -t box-js:probe .        # passes
sed -i '/libavif16/d' ubuntu/24.04/js/Dockerfile
docker build -f ubuntu/24.04/js/Dockerfile -t box-js:probe .        # fails
```
