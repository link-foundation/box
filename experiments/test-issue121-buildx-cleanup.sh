#!/usr/bin/env bash
# test-issue121-buildx-cleanup.sh
#
# The post-job builder removal is off on the runners where it can only warn.
#
# Why this exists (issue #121). docker/setup-buildx-action registers a post
# step that runs `docker buildx rm`, which deletes the BuildKit state volume.
# From buildx v0.36.0 that removal inherits the client's `--timeout` - 20s by
# default, documented for *loading builder status* - so deleting a volume
# holding a full-box build cache is cut off mid-flight (reproduced against the
# real daemon by experiments/issue-121-buildx-rm-timeout/). The action ignores
# the exit code and re-reports the stderr with `core.warning`, so a job that
# succeeded, pushed and published still carries
#
#   ERROR: failed to remove one or more builders
#
# as an annotation - run 34293699247's `full / docker-build-push`, 20.05s in.
# A GitHub-hosted runner is destroyed whole seconds later, so the cleanup buys
# nothing there; a self-hosted runner outlives the job and does want it.
#
# The assertions are about that decision staying enforced:
#
#   1. no workflow reaches docker/setup-buildx-action directly, so every buildx
#      setup in the repository goes through the composite and inherits this;
#   2. the composite passes `cleanup:` at all;
#   3. the expression it passes evaluates the way the comment claims - it is
#      evaluated here, not eyeballed, with GitHub's own truthiness rules.
#
# Offline: reads files, evaluates one expression. Nothing is run or fetched.
#
# Usage: bash experiments/test-issue121-buildx-cleanup.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ACTION=".github/actions/setup-buildx-resilient/action.yml"

PASS=0
FAIL=0
pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  if [ $# -gt 1 ]; then
    shift
    printf '      %s\n' "$@"
  fi
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 is not installed; this suite evaluates one expression with it."
  exit 0
fi

if [ -f "$ACTION" ]; then
  pass "$ACTION exists"
else
  fail "$ACTION is missing"
  echo
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

echo
echo "== Part 1: every buildx setup goes through the composite =="

direct="$(grep -rln 'uses:[[:space:]]*docker/setup-buildx-action' .github/workflows 2>/dev/null)"
if [ -z "$direct" ]; then
  pass "no workflow uses docker/setup-buildx-action directly"
else
  fail "a workflow bypasses the composite and so does not get this setting" \
    "$direct"
fi

users="$(grep -rl 'setup-buildx-resilient' .github/workflows 2>/dev/null | wc -l)"
setups="$(grep -rc 'setup-buildx-resilient' .github/workflows 2>/dev/null | awk -F: '{ n += $2 } END { print n + 0 }')"
if [ "$setups" -gt 0 ]; then
  pass "$setups buildx setups across $users workflows route through the composite"
else
  fail "no workflow uses the composite; this test would assert nothing"
fi

echo
echo "== Part 2: the composite passes a cleanup decision down =="

if grep -q '^  cleanup:' "$ACTION"; then
  pass "the composite declares a cleanup input"
else
  fail "the composite does not declare a cleanup input"
fi

# Empty, not 'false': an empty default is what lets the expression tell "the
# caller said nothing" from "the caller said false".
if awk '/^  cleanup:/ { in_it = 1 } in_it && /^    default:/ { print; exit }' "$ACTION" | grep -q "default: ''"; then
  pass "the cleanup input defaults to empty, so the runner decides"
else
  fail "the cleanup input does not default to empty"
fi

expr_line="$(grep -n 'cleanup: \${{' "$ACTION" | head -n 1)"
if [ -n "$expr_line" ]; then
  pass "the setup step passes cleanup: ($(echo "$expr_line" | cut -d: -f1))"
else
  fail "the setup step does not pass cleanup at all" \
    "docker/setup-buildx-action defaults it to true, so the warning returns"
fi

echo
echo "== Part 3: the expression means what the comment says =="

ACTION="$ACTION" python3 -c '
import os
import re
import sys

text = open(os.environ["ACTION"]).read()
m = re.search(r"^\s*cleanup:\s*\$\{\{(.*?)\}\}\s*$", text, re.M)
if not m:
    print("FAIL: could not find the cleanup expression in the composite")
    sys.exit(1)
source = m.group(1).strip()
print("  expression: %s" % source)


# A very small evaluator for the subset of the GitHub expression language this
# line uses. The point is that `&&` and `||` return an *operand*, not a
# boolean, and that an empty string is the only falsy string - which is exactly
# what makes `a != "" && a || b` work as "a, or else b".
def truthy(value):
    return value not in (False, "", 0, None)


TOKEN = re.compile(r"\s*(&&|\|\||!=|==|\(|\)|'"'"'[^'"'"']*'"'"'|[A-Za-z_][A-Za-z0-9_.-]*)")


def tokenize(s):
    out, i = [], 0
    while i < len(s):
        m = TOKEN.match(s, i)
        if not m:
            raise ValueError("cannot tokenize at %r" % s[i:])
        out.append(m.group(1))
        i = m.end()
    return out


class Parser:
    def __init__(self, tokens, context):
        self.t, self.i, self.ctx = tokens, 0, context

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def primary(self):
        tok = self.take()
        if tok == "(":
            v = self.or_()
            assert self.take() == ")"
            return v
        if tok.startswith("'"'"'"):
            return tok[1:-1]
        if tok in ("true", "false"):
            return tok == "true"
        if tok not in self.ctx:
            raise KeyError("unknown context value %r" % tok)
        return self.ctx[tok]

    def compare(self):
        left = self.primary()
        while self.peek() in ("!=", "=="):
            op = self.take()
            right = self.primary()
            left = (left != right) if op == "!=" else (left == right)
        return left

    def and_(self):
        left = self.compare()
        while self.peek() == "&&":
            self.take()
            right = self.compare()
            # GitHub returns the *last* evaluated operand, not a boolean.
            left = right if truthy(left) else left
        return left

    def or_(self):
        left = self.and_()
        while self.peek() == "||":
            self.take()
            right = self.and_()
            left = left if truthy(left) else right
        return left


def evaluate(cleanup_input, environment):
    ctx = {
        "inputs.cleanup": cleanup_input,
        "runner.environment": environment,
    }
    p = Parser(tokenize(source), ctx)
    value = p.or_()
    assert p.peek() is None, "trailing tokens: %r" % p.t[p.i:]
    # The runner stringifies the result before the action reads it, and
    # @actions/core parses "true"/"false" from that string.
    return str(value).lower()


cases = [
    ("nothing said, GitHub-hosted -> no removal, no warning",
     evaluate("", "github-hosted"), "false"),
    ("nothing said, self-hosted -> the builder is removed",
     evaluate("", "self-hosted"), "true"),
    ("the caller asked for cleanup on a hosted runner -> honoured",
     evaluate("true", "github-hosted"), "true"),
    ("the caller refused cleanup on a self-hosted runner -> honoured",
     evaluate("false", "self-hosted"), "false"),
]

failed = 0
for label, got, want in cases:
    ok = got == want
    failed += 0 if ok else 1
    print("%s: %s (got %s)" % ("PASS" if ok else "FAIL", label, got))
sys.exit(1 if failed else 0)
' >/tmp/issue121-buildx-cleanup-expr.out 2>&1
sed 's/^/  /' /tmp/issue121-buildx-cleanup-expr.out
PASS=$((PASS + $(grep -c '^PASS' /tmp/issue121-buildx-cleanup-expr.out)))
FAIL=$((FAIL + $(grep -c '^FAIL' /tmp/issue121-buildx-cleanup-expr.out)))
rm -f /tmp/issue121-buildx-cleanup-expr.out

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "All issue #121 buildx cleanup checks passed."
