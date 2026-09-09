`all_recovered` is computed from the re-asked subset alone, so a report holding one 404 and one connection reset ends the run green

**Reproduced at:** `__SHA__` — `scripts/recheck-broken-links.mjs:277-285`, `.github/workflows/links.yml:__WFLINES__`
**Introduced with:** the re-check added for #__PRIOR__. The re-check itself is right; the output it hands the workflow is too generous.

## What happens

`recheck-broken-links.mjs` re-asks only the failures no host answered, and never a
failure carrying a status code. That rule is exactly right. But the output the
workflow acts on is computed from the re-asked subset alone:

```js
// scripts/recheck-broken-links.mjs:277
  if (
    result.stillBroken.length === 0 &&
    result.recovered.length === unanswered.length
  ) {
    appendFileSync(
      process.env.GITHUB_OUTPUT || '/dev/null',
      'all_recovered=true\n'
    );
  }
```

`finalFailures` — the failures a host *did* answer (`[404]`, "Rejected status
code"), plus the ones with no URL to ask at all (a missing local file, an
unresolvable root-relative link) — is computed forty lines above, printed in the
summary line, and then never consulted again.

`links.yml` gates *both* remaining steps on that one output:

```yaml
      - name: Check broken links against Web Archive
        if: >-
          steps.lychee.outputs.exit_code != 0 &&
          steps.recheck.outputs.all_recovered != 'true'

      - name: Fail if broken links were found
        if: >-
          always() &&
          steps.lychee.outputs.exit_code != 0 &&
          steps.recheck.outputs.all_recovered != 'true'
```

So a report holding **one 404 and one connection reset** sets
`all_recovered=true`, skips the archive lookup, skips the failing step, and the
job ends green with the 404 still in `lychee/out.md` and still in the job
summary. `!= 'true'` is the correct fail-safe spelling and is not the problem
here: the output is genuinely `true`, it just does not mean what its two
consumers read it as.

The mixed report is the likely shape, not a corner case. The reset that motivated
#__PRIOR__ arrives at a random moment during a sweep of the whole tree, so the run
where it happens is just as likely to be a run that also has something genuinely
wrong — and that is precisely the run that now passes.

## Reproduction

Self-contained and offline: the "flaky host" is a local `http.server`, so the
recovered URL does not depend on the network.

```bash
git clone https://github.com/link-foundation/__REPO__ repro
cd repro

mkdir -p www lychee && echo ok > www/index.html
python3 -m http.server 8731 --bind 127.0.0.1 >/dev/null 2>&1 &
server=$!

cat > lychee/out.md <<'EOF'
## Errors per input

### Errors in README.md

- [404] <https://example.com/definitely-gone/> (at 48:130) | Rejected status code: 404 Not Found
- [ERROR] <http://127.0.0.1:8731/> (at 12:3) | error sending request: connection reset by peer
EOF

out=$(mktemp)
GITHUB_OUTPUT="$out" \
LYCHEE_OUTPUT=lychee/out.md \
RECOVERED_OUTPUT=lychee/recovered.txt \
RECHECK_BUDGET_SECONDS=20 RECHECK_WAIT_MS=200 \
  node scripts/recheck-broken-links.mjs

echo "== \$GITHUB_OUTPUT =="; cat "$out"
kill $server
```

Observed on `__SHORTSHA__`:

```
Re-check: 2 lychee failure(s), 1 answered and final, 1 never got an answer
::notice::http://127.0.0.1:8731/ never answered lychee but answers 100..=103,200..=299 now -- not a broken link
Re-check finished: 1 recovered, 0 still without an answer
== $GITHUB_OUTPUT ==
all_recovered=true
```

`all_recovered=true` while `https://example.com/definitely-gone/` is still an
unforgiven `[404]` in the report — and `links.yml` reads that output as "there is
nothing left to fail on".

Expected: `all_recovered` unset, both following steps run, the job fails on the
404 and the reset is not counted against it.

## Suggested fix

`all_recovered` is read as a verdict about the whole report, so it has to be
computed from the whole report. Two added conditions:

```diff
   if (
+    finalFailures.length === 0 &&
     result.stillBroken.length === 0 &&
+    unanswered.length > 0 &&
     result.recovered.length === unanswered.length
   ) {
     appendFileSync(
       process.env.GITHUB_OUTPUT || '/dev/null',
       'all_recovered=true\n'
     );
   }
```

`unanswered.length > 0` is not redundant defensiveness: without it the empty case
satisfies `0 === 0` and claims a clean report when nothing was re-asked at all.
The early `return` on `unanswered.length === 0` covers that path today, so the
guard costs nothing now and stops the next refactor from reintroducing it.

Worth extracting as a named predicate — `allRecovered({finalFailureCount,
stillBrokenCount, unansweredCount, recoveredCount})` — so the four interesting
cases (`finalFailureCount > 0`, `stillBrokenCount > 0`, `unansweredCount === 0`,
and the one true case) are unit-testable without a network.

The doc comment at the top of the file wants the matching sentence, since it is
what the current behaviour was written to:

```diff
- *   - all_recovered: 'true' when every unanswered link answered healthy on
+ *   - all_recovered: 'true' when the report contained nothing but unanswered
+ *     failures and every one of them answered healthy on
```

## Workaround, until the fix lands

Keep the failing step independent of the re-check and let the re-check downgrade
only what it is entitled to. The smallest version: have the script write a
second output holding the count of failures that are still real
(`final_failure_count`), and gate the failing step on

```yaml
        if: >-
          !cancelled() &&
          steps.lychee.outputs.exit_code != 0 &&
          (steps.recheck.outputs.all_recovered != 'true' ||
           steps.recheck.outputs.final_failure_count != '0')
```

That is strictly worse than fixing the predicate — it leaves `all_recovered`
misnamed for any future consumer — but it is a one-file change to `links.yml`
plus one `appendFileSync`.

(Unrelated to this bug, while you are in those conditions: `always()` on the
failing step also runs it after a cancellation. `!cancelled()` is the spelling
that keeps a cancelled run from being repainted red.)

## Also affected

`link-foundation/__SIBLING__` carries the same script — byte-identical apart from
two comments — and the same two `links.yml` conditions. Filed there as well.
The php, csharp, python and go templates have no `scripts/recheck-broken-links.mjs`
at all, so they are not affected by this one; they are still affected by
#__PRIOR__ itself.

## Where this came from

Found while porting the re-check into `link-foundation/box`
(link-foundation/box#121, link-foundation/box#122). The port keeps this
template's rule about which failures may be re-asked — that part is the good
idea worth copying — and diverges only on this predicate. The reproduction above
is the reduced form of
`experiments/issue-121-template-recheck/reproduce-all-recovered-false-negative.sh`
there, and the divergence is pinned by 39 offline assertions in
`experiments/test-issue121-links-recheck.sh`.
