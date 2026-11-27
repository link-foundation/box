## Problem

The helper truncates URLs at a closing parenthesis, removes meaningful terminal punctuation, and includes the successful redirect in the list of broken URLs.

Verified at `7a05d0515fac2966885b272302c1055985bc948b`. Archive suggestions may therefore be for another resource.

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
PYTHONPATH=scripts python3 -c 'from pathlib import Path; import sys; from check_web_archive import extract_broken_urls; print(extract_broken_urls(Path(sys.argv[1]).read_text()))' /tmp/lychee-archive.md
```

## Workaround and proposed fix

Copy the complete target from the original source and query Wayback manually. A lookup for a shortened URL or a redirect in the report cannot establish availability for the failing document.

Read bracketed URLs through the closing angle bracket and preserve all characters inside it. When per-input headings exist, read only Errors and Timeouts. Leave legacy bare URL compatibility in a separate branch. Add regression assertions for terminal punctuation, parentheses, and the successful redirect beside broken links. The expected list has exactly the two complete URLs from Errors.

Confirmed during the audit of link-foundation/box#135.
