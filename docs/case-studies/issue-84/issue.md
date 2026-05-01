# Issue #84 - Fix CI/CD bugs

Source: https://github.com/link-foundation/box/issues/84

Opened: 2026-04-30 07:15:14 UTC

## Body

https://github.com/link-foundation/box/actions/runs/25125551441/job/73637479652

Use all the best practices from CI/CD templates (check full file tree to compare for all GitHub workflow and CI/CD scripts file), if the same issue is found in template report issue also in templates:
- https://github.com/link-foundation/js-ai-driven-development-pipeline-template
- https://github.com/link-foundation/rust-ai-driven-development-pipeline-template

We should compare all files, so we don't have more CI/CD errors in the future and reuse all the best practices from these templates.

We need to download all logs and data related about the issue to this repository, make sure we compile that data to `./docs/case-studies/issue-{id}` folder, and use it to do deep case study analysis (also make sure to search online for additional facts and data), in which we will reconstruct timeline/sequence of events, list of each and all requirements from the issue, find root causes of the each problem, and propose possible solutions and solution plans for each requirement (we should also check known existing components/libraries, that solve similar problem or can help in solutions).

If there is not enough data to find actual root cause, add debug output and verbose mode if not present, that will allow us to find root cause on next iteration.

If issue related to any other repository/project, where we can report issues on GitHub, please do so. Each issue must contain reproducible examples, workarounds and suggestions for fix the issue in code.

Please plan and execute everything in a single pull request, you have unlimited time and context, as context autocompacts and you can continue indefinitely, do as much as possible in one go, until it is each and every requirement fully addressed, and everything is totally done.
