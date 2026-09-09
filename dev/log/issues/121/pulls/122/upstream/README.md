# Upstream reports filed from issue #121

Every defect below was reproduced here first; the bodies as filed are kept next
to this file so a later reader can see what was claimed without depending on the
upstream issue staying open.

| Report | Defect | Our fix while it is open |
| --- | --- | --- |
| [docker/buildx#4066](https://github.com/docker/buildx/issues/4066) — `docker-buildx-4066.md` | The `docker-container` driver bakes the whole `GITHUB_EVENT_PATH` payload into every builder at create time, and the default metadata-provenance mode `min` writes it to `--metadata-file`. `--provenance=false` does not stop it: that flag governs the image attestation, not the metadata file. | `BUILDX_METADATA_PROVENANCE: disabled` at workflow scope in all six building workflows |
| [docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612) — `docker-build-push-action-1612.md` | `src/main.ts` prints the metadata file to the job log with `core.info(JSON.stringify(metadata, null, 2))`, unescaped — so whatever buildx put in it is handed to the runner's command parser. `docker/bake-action` has the same line. | same as above: nothing reaches the log to be printed |
| [actions/runner#4692](https://github.com/actions/runner/issues/4692) — `actions-runner-4692.md` | `ActionCommand.TryParse` accepts the legacy `##[command]` prefix **anywhere** in a line, while `TryParseV2` requires `::command::` at the start. Printed third-party text can therefore raise `failure` annotations on a green job, and `stop-commands` is in the same registered set. | none available to a workflow author; fixed a layer up, at the source of the text |
| [jlumbroso/free-disk-space#41](https://github.com/jlumbroso/free-disk-space/issues/41#issuecomment-5597567292) | `large-packages` passes a fixed list of six package names to one `apt-get remove`; `google-chrome-stable` has no arm64 apt source, so on every arm64 runner apt exits 100 having removed **none** of the six, and the action converts that into a `::warning::`. Commented on the existing report with a controlled amd64/arm64 pair and a patch. | `.github/actions/free-disk-space` + `scripts/ci/reclaim-large-packages.sh`, which ask dpkg what is installed first |

The first three are one chain, not three independent bugs: buildx supplies the
text, build-push-action puts it in the log, the runner parses it. Each link
would be enough on its own to break it, which is why each is worth reporting —
and why our own fix targets the first link, the only one we can act on.

Evidence for the chain: `../probes/provenance-injection/`.
Evidence for the reclaim defect: `../ci-logs/job-js-build-{arm64,amd64}-*.log.gz`.
