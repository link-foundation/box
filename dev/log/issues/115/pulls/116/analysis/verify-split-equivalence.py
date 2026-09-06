#!/usr/bin/env python3
"""Compare the 3135-line release.yml against the workflows it was split into.

Issue #115, RC-8. The split moved 22 jobs out of .github/workflows/release.yml
into six `workflow_call` files. The release pipeline cannot be exercised by a
pull request - its build jobs only run on `push` to main or a manual dispatch -
so "the pull request went green" proves nothing about it. This script is the
evidence that the split *moved* the jobs rather than changing them.

It is deliberately not a CI gate. It compares the working tree against a frozen
snapshot of a file that is meant to keep changing, so as a gate it would start
failing for correct changes, and a gate that fails for correct changes gets
silenced - the exact failure mode issue #115 is about. Re-run it by hand:

    python3 dev/log/issues/115/pulls/116/analysis/verify-split-equivalence.py

It compares seven facts that a "just moved it" refactor must preserve exactly:

  1. job ids                    no job lost, and only the expected ones added
  2. `uses:` references         same actions at the same pinned versions
  3. step names                 same steps
  4. shell lines in `run:`      same commands
  5. `if:` conditions           same gating, per job
  6. image tag literals         same images published
  7. `timeout-minutes:`         same ceilings

Two rewrites were unavoidable, and both are applied as canonicalisations rather
than waved through, so anything *else* that moved still shows up:

  A. Data that used to cross jobs inside one workflow now crosses a workflow
     boundary, where only `inputs` and `jobs.<id>.outputs` exist. Every
     `needs.<job>.outputs.x` / `needs.<job>.result` that pointed outside the
     new file became an input; SUBS below maps each one back.
  B. Six `run:` blocks interpolated `${{ needs.… }}` directly into shell. Once
     those became `${{ inputs.… }}`, zizmor's template-injection rule flags
     them (an input is attacker-controllable in a way a sibling job's output is
     not), so each is now bound through a step-level `env:`. RUN_SUBS maps the
     old inline expressions and the new variables to the same placeholder.

The one difference that is not a rewrite is the hoist: the term
`needs.detect-changes.result == 'success' &&` was removed from the moved jobs
and now sits on the caller job in release.yml, which is checked explicitly
below rather than assumed.

No PyYAML: the parsing is line-based on purpose, so this runs on a bare
Python 3 with nothing installed (the sandbox this was written in has no yaml
module).
"""
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[7]
BEFORE = Path(__file__).with_name('release.yml.pre-split')
AFTER = [
    ROOT / '.github/workflows/release.yml',
    ROOT / '.github/workflows/pr-tests.yml',
    ROOT / '.github/workflows/release-js.yml',
    ROOT / '.github/workflows/release-essentials.yml',
    ROOT / '.github/workflows/release-languages.yml',
    ROOT / '.github/workflows/release-full.yml',
    ROOT / '.github/workflows/release-dind.yml',
]

# Jobs the split added, and why each one has to exist.
#
#   js, essentials, languages, full, dind, pr-tests
#       the caller jobs; they carry the `uses:` and the hoisted guard.
#   status
#       a called workflow cannot expose `needs.<job>.result` to its caller -
#       only `jobs.<id>.outputs` crosses the boundary - and four of the results
#       the conditions read belong to matrix jobs, whose rollup result no
#       per-leg step output can reproduce.
ADDED_JOBS = {'status', 'js', 'essentials', 'languages', 'full', 'dind', 'pr-tests'}

# The hoisted term. It came out of every one of the fifteen release-family jobs
# that moved - three per family - and out of nothing else.
HOIST = "needs.detect-changes.result == 'success' && "
HOIST_COUNT = 15
# Every caller job must carry it, or the hoist dropped a guard instead of
# moving it.
CALLER_JOBS = ['js', 'essentials', 'languages', 'full', 'dind']

# Rewrite A: cross-workflow data flow. Reverse of the substitutions the split
# applied, so both sides are compared in the pre-split vocabulary.
SUBS = [
    (r"fromJSON\(inputs\.changes\)\['([a-z-]+)'\]", r"needs.detect-changes.outputs.\1"),
    (r"fromJSON\(inputs\.changes\)\[", "needs.detect-changes.outputs["),
    (r"inputs\.js-amd64-result", "needs.build-js-amd64.result"),
    (r"inputs\.js-arm64-result", "needs.build-js-arm64.result"),
    (r"inputs\.essentials-amd64-result", "needs.build-essentials-amd64.result"),
    (r"inputs\.essentials-arm64-result", "needs.build-essentials-arm64.result"),
    (r"inputs\.languages-amd64-result", "needs.build-languages-amd64.result"),
    (r"inputs\.languages-arm64-result", "needs.build-languages-arm64.result"),
    (r"inputs\.js-manifest-result", "needs.js-manifest.result"),
    (r"inputs\.essentials-manifest-result", "needs.essentials-manifest.result"),
    (r"inputs\.languages-manifest-result", "needs.languages-manifest.result"),
    (r"inputs\.full-manifest-result", "needs.docker-manifest.result"),
    (r"inputs\.detect-changes-result", "needs.detect-changes.result"),
    (r"inputs\.version-check-result", "needs.version-check.result"),
    (r"inputs\.changeset-check-result", "needs.changeset-check.result"),
    (r"inputs\.js-built-amd64", "needs.build-js-amd64.outputs.built"),
    (r"inputs\.js-built-arm64", "needs.build-js-arm64.outputs.built"),
    (r"inputs\.essentials-built-amd64", "needs.build-essentials-amd64.outputs.built"),
    (r"inputs\.essentials-built-arm64", "needs.build-essentials-arm64.outputs.built"),
]

# Rewrite B: the six run: blocks zizmor made us bind through env:. Applied to
# shell lines only - in an `if:` these expressions are not attacker-controllable
# and were left alone, so canonicalising them there would hide a real change.
RUN_SUBS = [
    (r"\$\{\{needs\.build-[a-z]+-(amd64|arm64)\.outputs\.built\}\}", "${}"),
    (r"\$\{\{needs\.build-languages-(amd64|arm64)\.result\}\}", "${}"),
    (r"\$UPSTREAM_BUILT", "${}"),
    (r"\$LANGUAGES_RESULT", "${}"),
]

BLOCK_SCALARS = ('|', '>', '|-', '>-', '|+', '>+')


def parse(path):
    """-> {job_id: {'runs': [...], 'ifs': [...], 'uses': [...], ...}}"""
    lines = path.read_text().split('\n')
    jobs = {}
    job = None
    in_jobs = False
    i = 0
    while i < len(lines):
        raw = lines[i]
        if raw.rstrip() == 'jobs:':
            in_jobs = True
            i += 1
            continue
        if in_jobs:
            m = re.match(r'^  ([a-z0-9][a-z0-9_-]*):\s*$', raw)
            if m:
                job = m.group(1)
                jobs.setdefault(job, {k: [] for k in
                                      ('runs', 'ifs', 'uses', 'steps', 'tags', 'timeouts')})
                i += 1
                continue
        if job is None:
            i += 1
            continue
        d = jobs[job]

        m = re.match(r'^\s*(?:- )?uses: (\S+)', raw)
        if m:
            d['uses'].append(m.group(1))
        m = re.match(r'^\s*- name: (.+)$', raw)
        if m:
            d['steps'].append(m.group(1).strip())
        m = re.match(r'^\s*timeout-minutes: (\d+)', raw)
        if m:
            d['timeouts'].append(m.group(1))
        for t in re.findall(r'-[a-z0-9]+:[a-z0-9.${}_-]+', raw):
            d['tags'].append(t)

        m = re.match(r'^(\s*)(?:- )?(run|if): (.*)$', raw)
        if m:
            indent = len(m.group(1)) + (2 if raw.lstrip().startswith('- ') else 0)
            key, first = m.group(2), m.group(3).strip()
            if first in BLOCK_SCALARS:
                body = []
                i += 1
                while i < len(lines):
                    nxt = lines[i]
                    if nxt.strip() == '':
                        i += 1
                        continue
                    if len(nxt) - len(nxt.lstrip()) <= indent:
                        break
                    body.append(nxt.strip())
                    i += 1
            else:
                body = [first]
                i += 1
            body = [b for b in body if b and not b.startswith('#')]
            d['runs' if key == 'run' else 'ifs'].extend(
                body if key == 'run' else [' '.join(body)])
            continue
        i += 1
    return jobs


def canon(s, extra=()):
    # Normalise whitespace inside ${{ }} so `${{ x }}` and `${{x}}` compare equal.
    s = re.sub(r'\$\{\{(.*?)\}\}', lambda m: '${{' + m.group(1).strip() + '}}', s)
    for a, b in list(SUBS) + list(extra):
        s = re.sub(a, b, s)
    return re.sub(r'\s+', ' ', s).strip()


def collect(paths, exclude=()):
    out = {k: [] for k in ('runs', 'ifs', 'uses', 'steps', 'tags', 'timeouts')}
    ids = set()
    for p in paths:
        for job, d in parse(p).items():
            ids.add(job)
            if job in exclude:
                continue
            out['runs'] += [canon(x, RUN_SUBS) for x in d['runs']]
            out['ifs'] += [(job, canon(x)) for x in d['ifs']]
            out['uses'] += [x for x in d['uses'] if not x.startswith('./.github/workflows/')]
            out['steps'] += d['steps']
            out['tags'] += [canon(x) for x in d['tags']]
            out['timeouts'] += d['timeouts']
    return ids, out


def diff(name, before, after):
    b, a = Counter(before), Counter(after)
    only_b, only_a = b - a, a - b
    if not only_b and not only_a:
        print(f'  OK   {name}: {sum(b.values())} entries, identical')
        return True
    print(f'  DIFF {name}:')
    for k, n in sorted(only_b.items()):
        print(f'    -{n} {k}')
    for k, n in sorted(only_a.items()):
        print(f'    +{n} {k}')
    return False


def main():
    if not BEFORE.exists():
        print(f'missing snapshot: {BEFORE}', file=sys.stderr)
        return 2

    bids, b = collect([BEFORE])
    aids, a = collect(AFTER, exclude=ADDED_JOBS)

    print(f'before: {BEFORE.relative_to(ROOT)} '
          f'({len(BEFORE.read_text().splitlines())} lines, {len(bids)} jobs)')
    for p in AFTER:
        print(f'after:  {p.relative_to(ROOT)} ({len(p.read_text().splitlines())} lines)')
    print()

    # The hoist, undone on the before side so the rest of each condition can be
    # compared, and counted so a *silently dropped* guard cannot pass as one.
    # Only for the jobs that moved into a release-*.yml. Two groups keep the
    # term: the jobs that stayed in release.yml still sit next to detect-changes
    # and name it directly, and the pull-request jobs take the result as an
    # explicit `detect-changes-result` input, because there the guard is the
    # difference between "no build needed" and "we could not tell", which the
    # caller-level hoist would flatten.
    keeps_guard = set(parse(ROOT / '.github/workflows/release.yml'))
    keeps_guard |= set(parse(ROOT / '.github/workflows/pr-tests.yml'))
    keeps_guard -= {'js', 'essentials', 'languages', 'full', 'dind'}
    hoisted = sum(1 for job, x in b['ifs'] if HOIST in x and job not in keeps_guard)
    b['ifs'] = [x.replace(HOIST, '') if job not in keeps_guard else x
                for job, x in b['ifs']]
    a['ifs'] = [x for _, x in a['ifs']]

    ok = True
    lost, gained = bids - aids, aids - bids - ADDED_JOBS
    if lost or gained:
        ok = False
        print(f'  DIFF job ids: lost={sorted(lost)} unexpected={sorted(gained)}')
    else:
        print(f'  OK   job ids: {len(bids)} before, {len(aids)} after '
              f'(+{len(aids - bids)} expected: {sorted(aids - bids)})')

    for key, label in (('uses', 'uses: references'), ('steps', 'step names'),
                       ('runs', 'shell lines in run:'), ('ifs', 'if: conditions'),
                       ('tags', 'image tag literals'), ('timeouts', 'timeout-minutes')):
        ok &= diff(label, b[key], a[key])

    moved = {j for j in bids if j not in keeps_guard}
    if hoisted == HOIST_COUNT == len(moved):
        print(f'  OK   hoisted guard: removed from all {hoisted} moved '
              f'release-family jobs, and from no other job')
    else:
        ok = False
        print(f'  DIFF hoisted guard: {hoisted} occurrences removed, '
              f'{len(moved)} jobs moved, expected {HOIST_COUNT} of each')

    # ... and it has to reappear on every caller job, or the guard was dropped.
    caller = parse(ROOT / '.github/workflows/release.yml')
    for j in CALLER_JOBS:
        conds = ' '.join(caller.get(j, {}).get('ifs', []))
        if "needs.detect-changes.result == 'success'" in re.sub(r'\s+', ' ', conds):
            print(f'  OK   caller job {j!r} carries the hoisted guard')
        else:
            ok = False
            print(f'  DIFF caller job {j!r} does not carry the hoisted guard')

    print()
    print('EQUIVALENT' if ok else 'DIFFERENCES FOUND')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
