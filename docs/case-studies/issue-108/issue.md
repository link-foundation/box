# Issue #108: We should not execute tests or any other CI/CD when only non essential files like .gitkeep changes

https://github.com/link-foundation/box/pull/107/commits/eaeed07bcfc8b5b9069a0c5bb8d2307f2bc6744b - this commit triggered tests, but there is no changes in docker files or scripts.

Also changes to docs and other files should be ignored. So only files that actually affect docker image builds should be triggering tests and other CI/CD actions.

That will save GitHub Actions resources, and speed up our iterations.

We also must check https://github.com/link-foundation/box/actions/runs/27826405731 for any false positives and errors, and  fix them all. Including all warnings.

Use all the best practices from CI/CD templates (check full file tree to compare for all GitHub workflow and CI/CD scripts file), if the same issue is found in template report issue also in templates:
- https://github.com/link-foundation/js-ai-driven-development-pipeline-template
- https://github.com/link-foundation/rust-ai-driven-development-pipeline-template
- https://github.com/link-foundation/python-ai-driven-development-pipeline-template
- https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template

We should compare all files, so we don't have more CI/CD errors in the future and reuse all the best practices from these templates.

We need to download all logs and data related about the issue to this repository, make sure we compile that data to `./docs/case-studies/issue-{id}` folder, and use it to do deep case study analysis (also make sure to search online for additional facts and data), in which we will reconstruct timeline/sequence of events, list of each and all requirements from the issue, find root causes of the each problem, and propose possible solutions and solution plans for each requirement (we should also check known existing components/libraries, that solve similar problem or can help in solutions).

If there is not enough data to find actual root cause, add debug output and verbose mode if not present, that will allow us to find root cause on next iteration.

If issue related to any other repository/project, where we can report issues on GitHub, please do so. Each issue must contain reproducible examples, workarounds and suggestions for fix the issue in code. Also double check to fully apply requirements to entire codebase, so if we have issue in multiple places, it should be fixed in all them.

Please plan and execute everything in this single pull request, you have unlimited time and context, as context auto-compacts and you can continue indefinitely, until it is each and every requirement fully addressed, and everything is totally done.
