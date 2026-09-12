# Complete warning/error census dispositions

`warnings-errors.raw.tsv` contains every case-insensitive `warn` or `error`
match in all nine run logs: **2,598 lines**. The generator first preserves job
and source identity, tracks GitHub workflow-command suspension, and then assigns
one mutually exclusive class. The generated `warnings-errors.census.md` lists
every distinct tool/annotation text and every BuildKit warning text.

| Class | Lines | Distinct | Disposition |
| --- | ---: | ---: | --- |
| `annotation` | 3 | 2 | True propagation of RC-1; fixed at source. |
| `tool` | 1,851 | 46 | 1,800 missing control-file errors are RC-1. Four Docker copy failures (eight emitted lines) recovered on retry. The rest are successful checker summaries, filenames, fields, or installer messages dispositioned below. |
| `bracketed-text` | 1 | 1 | Quoted workflow command while command processing is stopped; API confirms inert. |
| `assertion` | 16 | 15 | Test fixtures proving warning/error paths; not emitted CI findings. |
| `action-help` | 42 | 3 | Action metadata/help fields such as `description`; not findings. |
| `step-script` | 571 | 21 | Runner echo of scripts about to execute; text is source, not output. |
| `docker-build` | 114 | 114 | BuildKit progress. Warning-token subset is the package-manager group in RC-5; many others are command/package names containing `error`. |

## Tool-class closure

- **1,800 missing paths:** false CI failure and lost output; fixed and
  regression-tested.
- **8 registry error emissions / 4 operations:** genuine failed first attempts,
  successful second attempts, zero annotations; retain.
- **CodeQL diagnostics:** query names (`ExtractionErrors`,
  `ExtractionWarnings`), result paths, and configuration fields. All CodeQL jobs
  succeeded with zero findings annotations; retain.
- **Gate summaries:** `No shellcheck findings`, lychee `Errors | 0`, secretlint
  budget labels, and regression fixture names. These explicitly report success;
  retain.
- **File/path matches:** files named for warning/error regression tests and the
  evidence snapshots surfaced by change detection. They are inputs, not
  findings; retain.
- **Installer warnings:** truthful intermediate state immediately resolved and
  verified by the image builds; retain, as explained in RC-5.

The three annotation records, zero-annotation claims, job conclusions, and
notice level were checked against the API JSON in `../annotations/`, not inferred
from this lexical census.
