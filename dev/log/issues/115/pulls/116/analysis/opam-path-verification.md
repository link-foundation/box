# Evidence: `opam` is missing from PATH in the published boxes (issue #115)

## Symptom, on the images that are live right now

```console
$ docker run --rm konard/box:latest rocq --version
The Rocq Prover, version 9.2
$ docker run --rm konard/box:latest opam --version
/usr/local/bin/entrypoint.sh: line 57: exec: opam: not found

$ docker run --rm konard/box-rocq:latest bash -c 'command -v opam; echo "exit=$?"'
exit=1
```

The README advertises "Opam, Rocq prover". Both boxes ship a working `rocq`
and no reachable `opam`, so neither box can install another Rocq package —
and no CI check noticed, because no job ran `opam` at all. That is the
false negative; the two lines below are the defect it hid.

## Root cause

1. `ubuntu/24.04/rocq/install.sh` installs the opam binary into
   `$HOME/.local/bin` (it is running as the unprivileged `box` user and cannot
   write `/usr/local/bin`), and puts the *switch* on PATH via
   `ubuntu/24.04/rocq/Dockerfile`:
   `ENV PATH="/home/box/.opam/default/bin:${PATH}"`. `~/.local/bin` was never
   added, so `opam` resolved only in a shell that had sourced `~/.bashrc` —
   which `docker run`, `docker exec` and every CI step do not.

   ```console
   $ docker run --rm konard/box-rocq:latest bash -c 'ls -la /home/box/.local/bin; echo "PATH=$PATH"'
   -rwxr-xr-x 1 box box 8944496 Jun 21 17:27 opam
   PATH=/home/box/.nvm/...:/home/box/.opam/default/bin:...   # no ~/.local/bin
   ```

2. `ubuntu/24.04/full-box/Dockerfile` copied `~/.opam` out of the rocq stage
   and nothing else. `COPY --from` copies the paths it is given, so the switch
   arrived and the binary — which lives outside `~/.opam` — did not.

## Fix, verified against the published images

`dev/log/issues/115/pulls/116/analysis/opam-path-verification.Dockerfile`
applies both changes on top of the live images and runs `opam --version`:

- rocq box: `ENV PATH="/home/box/.local/bin:${PATH}"` → `opam 2.5.1`
- full box: `COPY --from=rocq-stage /home/box/.local/bin/opam /usr/local/bin/opam` → `opam 2.5.1`

Build log: `opam-path-verification.log` (steps #7 and #9 both print `2.5.1`
followed by `The Rocq Prover, version 9.2`).

## Regression check

`scripts/ci/test-box.sh` asserts `opam --version` in the `rocq` profile, and
the `full` profile runs every per-language check, so both the standalone rocq
box and the full box now have to answer it — in the pre-merge test *and* in the
smoke test of the pushed image, which run the same script.
