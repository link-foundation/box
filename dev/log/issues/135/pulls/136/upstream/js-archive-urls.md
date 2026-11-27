## Problem

The helper truncates the path at a closing parenthesis and removes a trailing period from an explicit Markdown autolink.

Verified at `8e72538d579d904aff818c2447fb3c2413d3a989`. Archive suggestions may therefore be for another resource.

## Offline reproduction

Save this as `/tmp/lychee-archive.md` and run the command from the template root.

```markdown
# Summary
| Errors | 2 |
| Timeouts | 0 |
## Errors per input
* [404] <https://example.com/docs.> | Rejected status code: 404
* [404] <https://example.com/path(part)> | Rejected status code: 404
## Redirects per input
* https://example.com/old --[301]--> https://example.com/new
```

```bash
node --input-type=module -e 'import { readFileSync } from "node:fs"; import { extractBrokenLinks } from "./scripts/check-web-archive.mjs"; console.log(extractBrokenLinks(readFileSync(process.argv[1], "utf8")).urls);' /tmp/lychee-archive.md
```

## Workaround and proposed fix

Copy the complete target from the original source and query Wayback manually. A lookup for a shortened URL or a redirect in the report cannot establish availability for the failing document.

Read bracketed URLs through the closing angle bracket and preserve all characters inside it. When per-input headings exist, read only Errors and Timeouts. Leave legacy bare URL compatibility in a separate branch. Add regression assertions for terminal punctuation, parentheses, and the successful redirect beside broken links. The expected list has exactly the two complete URLs from Errors.

Confirmed during the audit of link-foundation/box#135.
