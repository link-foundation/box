## Problem

The helper removes a trailing period from the URL even inside the explicit Markdown autolink, so Wayback receives a different resource path.

Verified at `e12a25d7ce9d8bfd37f238b1b238c0006bf52031`. Archive suggestions may therefore be for another resource.

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
php -r 'require "scripts/src/WebArchive.php"; print_r(LinkFoundation\Template\Pipeline\WebArchive::extractUrls(file_get_contents($argv[1])));' /tmp/lychee-archive.md
```

## Workaround and proposed fix

Copy the complete target from the original source and query Wayback manually. A lookup for a shortened URL or a redirect in the report cannot establish availability for the failing document.

Read bracketed URLs through the closing angle bracket and preserve all characters inside it. When per-input headings exist, read only Errors and Timeouts. Leave legacy bare URL compatibility in a separate branch. Add regression assertions for terminal punctuation, parentheses, and the successful redirect beside broken links. The expected list has exactly the two complete URLs from Errors.

Confirmed during the audit of link-foundation/box#135.
