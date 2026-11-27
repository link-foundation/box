- [x] The warning came from running the official install script.
- [x] I read the checkout and network troubleshooting page. The local reproduction uses no network.
- [x] This installer attempt stopped before installation. The runner was Ubuntu 24.04.5 LTS x86-64 (GitHub-hosted ubuntu-24.04, image 20261122.23.1).

## What I was trying to do

Install Homebrew alongside other toolchains on a GitHub-hosted Linux runner as part of an on-disk size measurement.

## What happened

The installer printed two libc version probe diagnostics before its separate, accurate existing-prefix permission error.

```text
==> Checking for `sudo` access...
/usr/bin/ldd: line 41: printf: write error: Broken pipe
/usr/bin/ldd: line 43: printf: write error: Broken pipe
Insufficient permissions to install Homebrew to "/home/linuxbrew/.linuxbrew".
```

The public measurement run is https://github.com/link-foundation/box/actions/runs/45954663314, in the Measure Component Disk Space job. The permission error comes from the preinstalled runner prefix and is handled by that project. This report concerns the two earlier diagnostics, which I reproduced independently.

## Expected behavior

The libc probe reads its version without emitting a pipe write diagnostic.

## Reproduction and suggested repair

[`outdated_glibc`](https://github.com/Homebrew/install/blob/870ddff5dbe61d293a8b4a763090d125e59048a1/install.sh#L562-L567) pipes `ldd --version` through `head -n1`. The reader can close the pipe while the producer is still printing. With SIGPIPE ignored, the Ubuntu ldd shell implementation prints the same diagnostics as the runner.

```bash
for ((trial=0; trial<60; trial++)); do
  (trap '' PIPE; /usr/bin/ldd --version) | head -n1 >/dev/null
done
```

A workaround for callers using a local copy of the installer is to replace `head -n1` with `sed -n '1p'` in the probe. The latter prints just the first line while draining the remaining input. The same test had zero diagnostics with that change. The remainder of the version extraction can stay as-is.

```bash
glibc_version="$(ldd --version | sed -n '1p' | grep -o '[0-9.]*$' | grep -o '^[0-9]\+\.[0-9]\+')"
```
