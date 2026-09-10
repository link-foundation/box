# Evidence for issue #123 / pull request #124

Everything issue #123 was answered from, 7.4 MB of it, collected before any fix
was written and never edited afterwards. The rule this directory follows is the
one the issue is about: **a claim is only as good as the artefact it can be
checked against.** Every number quoted in `analysis/`, in the changeset, and in
the pull request body resolves to a file here.

The scope is fixed: the **nine workflow runs on `main` at commit `1d9fb3e`**
that the issue lists — eight green, one cancelled — plus the release run's 99
jobs.

## What is here

| Directory | Files | Size | What it holds |
| --- | ---: | ---: | --- |
| `ci-logs/` | 113 | 3.1M | the nine run logs (`<run-id>.log.gz`), every step log of the release run (`release-34366976358/`), and the individual job logs the analysis cites (`jobs/`) |
| `templates/` | 269 | 2.3M | pinned checkouts of the seven `*-ai-driven-development-pipeline-template` repositories plus box's own file tree, `COMPARISON.md` (160 script roles × 17 workflow roles, 91 gaps dispositioned), `SNAPSHOT.txt` (the seven SHAs), and the hive-mind best-practices file at the commit it was read at |
| `upstream/` | 58 | 764K | the six defect classes reported to other projects: bodies, rendered form, reproduction evidence, and `filed/index.tsv` mapping each to its URL |
| `runs/` | 22 | 792K | `gh api` records — `<run-id>.run.json` and `<run-id>.jobs.json` for all nine |
| `analysis/` | 9 | 384K | the written analysis; see `analysis/README.md` |
| `annotations/` | 10 | 52K | the annotation payload of each run, and `README.md` — the seven annotations, with the verdict on each |
| `zizmor/` | 7 | 36K | the offline-vs-online audit comparison behind RC-5 |
| `apt/` | 2 | 20K | the full retry measurement, including the idle-timeout legs the suite keeps off by default |
| `useradd/` | 2 | 16K | the `/etc/skel` reproduction behind RC-10 |
| `npm-force/` | 1 | 12K | the twelve-run `npm --force` measurement behind RC-8 |

## How it was collected, and how to collect it again

| Script | Produces |
| --- | --- |
| `experiments/issue-123/collect-ci-evidence.mjs` | `runs/`, `annotations/`, `ci-logs/` |
| `experiments/issue-123/snapshot-templates.sh` | `templates/` |
| `experiments/issue-123/census-warnings-errors.sh` | `analysis/warnings-errors.raw.tsv` |
| `experiments/issue-123/compare-template-roles.sh` | the role matrix in `templates/COMPARISON.md` — offline, from the snapshot |
| `experiments/issue-123/render-upstream-reports.sh` | `upstream/rendered/` |
| `experiments/issue-123/file-upstream-reports.sh` | `upstream/filed/index.tsv` |

`collect-ci-evidence.mjs` records what it could not get. A log it fails to
fetch is stored as `LOG UNAVAILABLE: <the error>` (line 91) rather than as an
empty file, and a run already collected is never refetched — both `.log` and
`.log.gz` names are checked. That is deliberate: an evidence collector that
silently produces a zero-byte log is the same defect the issue exists to remove.
Eight of the nine run-level logs carry real content; the ninth
(`34366976358.log.gz`, the 99-job release run) is that recorded refusal —
`gh` declines to assemble a run log of that size — which is why all 99 of its
jobs were fetched individually into `ci-logs/release-34366976358/`. The
placeholder is legible as one, and `ci-logs/README.md` says so in the table.

## The shortest path through it

1. `analysis/REQUIREMENTS.md` — every requirement, and the artefact answering it.
2. `analysis/TIMELINE.md` — what actually happened at `1d9fb3e`, to the second.
3. `analysis/ROOT-CAUSES.md` — the nineteen mechanisms and the fix each got.
4. `annotations/README.md` — the seven annotations; three said something untrue.
