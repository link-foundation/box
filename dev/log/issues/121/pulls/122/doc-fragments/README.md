# The link checker never checked an anchor

Issue #121, finding (r). `.github/workflows/links.yml` has resolved every URL in
the tracked markdown since issue #115. It resolved the *document*: given
`docs/RELEASING.md#making-the-ghcr-packages-public`, lychee fetched
`docs/RELEASING.md`, found it, and reported OK — whatever headings that file
happens to contain today. An anchor is the part of a link a heading rename
breaks, and it was the part nothing looked at.

27 links in the corpus carry a fragment (14 into this repository, 13 remote);
see `corpus-fragment-coverage.txt` for how that was counted.

## Is the flag what makes the difference?

`mutation-fixture-offline.txt`. Two files, one same-file anchor
(`a.md#the-section`) and one cross-file anchor (`b.md#other-heading`), with both
target headings renamed. Same corpus, same image, one flag apart:

| command | result |
| --- | --- |
| `lychee --offline --include-fragments './**/*.md'` | 2 errors, `Cannot find fragment`, exit 2 |
| `lychee --offline './**/*.md'` | `2 OK 🚫 0 Errors`, exit 0 |

`--offline` keeps the fixture on the filesystem, so it needs docker but no
network and finishes in milliseconds. It is
`experiments/test-issue115-links-gate.sh`, Part "the fragment flag is
load-bearing" — four assertions, all of which fail if the flag is dropped from
the workflow's args or if lychee stops honouring it.

## What it found when it was first turned on

`online-include-fragments-sample.txt` — the first pass with the flag, over the 9
files that carry remote fragment links: **4 errors on 3 URLs**. Not false
positives; each was opened in a real browser and the anchor confirmed gone:

| URL | verdict | fix |
| --- | --- | --- |
| `docs.docker.com/engine/containers/run/#entrypoint-default-command-to-execute-at-runtime` (twice, `docs/case-studies/issue-62/CASE-STUDY.md:128` and `:178`) | the page was restructured; the section is now `Default entrypoint` | `#default-entrypoint` |
| `github.com/jpetazzo/dind#warning-the-resulting-images-are-not-meant-to-replace-real-vms` (`docs/case-studies/issue-80/research.md:32`) | the README's warning heading was reworded | `#a-word-of-warning` |
| `docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources` (`docs/case-studies/issue-29/README.md:278`) | GitHub moved the page under `/reference/runners/`; the redirect lands on a page without that id | `docs.github.com/en/actions/reference/runners/github-hosted-runners#supported-runners-and-hardware-resources` |

`online-include-fragments-after-fix.txt` — the same 9 files after the three
edits: 68 total, 55 unique, **68 OK, 0 errors** in 2.5 s.

`online-include-fragments-readme.txt` — README.md alone, the file with the most
external links: 112 total, 107 unique, 109 OK, 0 errors, 3 excluded.

`online-include-fragments-full.txt` — the whole corpus, online, with the flag:
**678 total, 470 unique, 664 OK, 0 errors**, 14 excluded, 12.8 s. Enabling the
flag costs nothing in requests (lychee already fetched those pages; it was
discarding their ids) and adds no false positive on this tree today.

## Reproduce

```
docker run --rm -v "$PWD:/repo" -w /repo lycheeverse/lychee:0.24.2 \
  --no-progress --include-fragments --max-retries 2 --timeout 30 \
  --exclude-path dev/log './**/*.md'

bash experiments/test-issue115-links-gate.sh    # offline + the docker fixture
```
