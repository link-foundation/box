#!/usr/bin/env bash
#
# check-heredoc-vars.sh — catch variables that leak out of a quoted heredoc.
#
# Issue #115 / root cause RC-1. A script that generates another script like this
#
#     NODE_MAJOR="$(resolve_node_lts_major)"
#     cat > /tmp/box-measure.sh << 'EOF_BOX'
#     ...
#     echo "Installing Node ${NODE_MAJOR}"
#     EOF_BOX
#     su - box -c "bash /tmp/box-measure.sh"
#
# looks right and is wrong. The quotes around EOF_BOX suppress expansion, so the
# generated file contains the literal characters $NODE_MAJOR, and `su -` starts a
# login shell that does not inherit the parent's variables. Under `set -u` the
# generated script dies with
#
#     /tmp/box-measure.sh: line 128: NODE_MAJOR: unbound variable
#
# which is what failed run 33972074753 on main.
#
# No off-the-shelf linter finds this. ShellCheck's SC2087 covers the opposite
# mistake (an *unquoted* heredoc piped to ssh), it does not analyse heredoc
# bodies as scripts (koalaman/shellcheck#108), and SC2154 deliberately exempts
# ALL-CAPS names as presumed environment variables — and every name in RC-1 is
# ALL-CAPS. Hence this check.
#
# WHAT IT CHECKS
#   For every quoted heredoc that writes a shell script (a redirection to a path
#   ending in .sh/.bash, or a heredoc explicitly marked `# heredoc-script`),
#   every expansion of a variable in the body must be one of:
#     1. assigned inside the body;
#     2. asserted inside the body as an intentional injection, with
#        `: "${NAME:?...}"` — which also turns a future omission into a named
#        error instead of a bare line number;
#     3. a standard environment or shell variable (see ENV_ALLOWLIST);
#     4. unset-tolerant, i.e. ${NAME:-default}, ${NAME-d}, ${NAME:+a}, ${NAME:=d},
#        none of which can abort under set -u.
#   Text that the shell would never expand is not a reference: single-quoted
#   strings, backslash-escaped \$NAME, and comments are all skipped, so a
#   `sed 's/\$FOO/x/'` line is not reported.
#
# USAGE
#   scripts/ci/check-heredoc-vars.sh [--verbose] [file ...]
#
#   With no files, checks every tracked *.sh in the repository.
#   --verbose (default off) prints every heredoc found and every reference
#   classified, which is what you want when a finding looks wrong.
#
# EXIT
#   0 = clean, 1 = at least one leaked variable, 2 = usage error.

set -euo pipefail

VERBOSE=0
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "check-heredoc-vars.sh: unknown option $1" >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done
FILES+=("$@")

if [ "${#FILES[@]}" -eq 0 ]; then
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  cd "$ROOT"
  while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.sh')
fi

# Standard environment and shell variables. A generated script may rely on these
# because the login shell that runs it sets them itself.
ENV_ALLOWLIST='HOME PATH USER LOGNAME SHELL PWD OLDPWD TERM LANG LANGUAGE TMPDIR
TZ EDITOR VISUAL PAGER HOSTNAME HOSTTYPE MACHTYPE OSTYPE DISPLAY XDG_RUNTIME_DIR
XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME SHLVL IFS PS1 PS2 PS3 PS4
PROMPT_COMMAND RANDOM SECONDS LINENO EPOCHSECONDS EPOCHREALTIME UID EUID GROUPS
BASH BASH_VERSION BASH_VERSINFO BASH_SOURCE BASH_SUBSHELL BASHPID FUNCNAME REPLY
OPTARG OPTIND PIPESTATUS LINES COLUMNS SUDO_USER SUDO_UID SUDO_GID MAIL HISTFILE'

status=0
findings_total=0

for file in "${FILES[@]}"; do
  [ -f "$file" ] || continue
  out="$(
    VERBOSE="$VERBOSE" ENV_ALLOWLIST="$ENV_ALLOWLIST" \
    awk -v FILE="$file" '
      BEGIN {
        verbose = (ENVIRON["VERBOSE"] == "1")
        n = split(ENVIRON["ENV_ALLOWLIST"], a, /[ \t\n]+/)
        for (i = 1; i <= n; i++) if (a[i] != "") allowed[a[i]] = 1
        in_doc = 0; findings = 0
      }

      # ---- inside a heredoc body -------------------------------------------
      in_doc {
        stripped = $0; sub(/^[ \t]*/, "", stripped)
        if (stripped == delim) { finish(); next }
        body_line[++body_n] = $0
        body_lineno[body_n] = NR
        next
      }

      # ---- looking for a script-generating quoted heredoc -------------------
      {
        prev_marker = marker; marker = 0
        if ($0 ~ /#[ \t]*heredoc-script/) { marker = 1; next }

        # A quoted delimiter is what suppresses expansion: <<EOF is fine.
        if (match($0, /<<-?[ \t]*(\47[A-Za-z_][A-Za-z0-9_]*\47|"[A-Za-z_][A-Za-z0-9_]*")/)) {
          d = substr($0, RSTART, RLENGTH)
          sub(/^<<-?[ \t]*/, "", d)
          gsub(/[\47"]/, "", d)

          # Only bodies that become a shell script are checked; a quoted heredoc
          # holding prose, JSON or a config file is not a script and may
          # legitimately contain text that merely looks like a variable.
          is_script = prev_marker || ($0 ~ /(>|>>|tee[ \t]+(-a[ \t]+)?)[ \t]*[^ \t]*\.(sh|bash)([ \t]|$)/)

          if (is_script) {
            in_doc = 1; delim = d; open_line = NR; body_n = 0
            if (verbose) printf "  [heredoc] %s:%d opens %s (script-generating)\n", FILE, NR, d
          } else if (verbose) {
            printf "  [heredoc] %s:%d opens %s (skipped: does not generate a .sh)\n", FILE, NR, d
          }
        }
      }

      END { if (in_doc) finish(); exit (findings > 0 ? 1 : 0) }

      # ----------------------------------------------------------------------
      # Blank out every region the shell would not expand, so that only real
      # expansions survive: single-quoted strings, backslash escapes and
      # comments. Quote state carries across lines, because a heredoc body is a
      # script and its strings may span lines.
      function strip(line,   out, i, c, nxt) {
        out = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (in_sq) { if (c == "\47") in_sq = 0; out = out " "; continue }
          if (c == "\\") { out = out "  "; i++; continue }   # escape: \$ is literal
          if (c == "\47" && !in_dq) { in_sq = 1; out = out " "; continue }
          if (c == "\"") { in_dq = !in_dq; out = out " "; continue }
          if (c == "#" && !in_dq) {
            # A comment starts only where a word can start.
            nxt = (i == 1) ? " " : substr(out, i - 1, 1)
            if (nxt ~ /[ \t;&|(]/ || i == 1) { while (length(out) < length(line)) out = out " "; return out }
          }
          out = out c
        }
        return out
      }

      function finish(   i, ln, name, op, op2, rest, pos, tok, j, k) {
        delete assigned; delete asserted; delete refs
        in_sq = 0; in_dq = 0

        for (i = 1; i <= body_n; i++) {
          ln = strip(body_line[i])

          # --- names bound inside the body -----------------------------------
          rest = ln
          while (match(rest, /(^|[ \t;&|(){])[A-Za-z_][A-Za-z0-9_]*\+?=/)) {
            tok = substr(rest, RSTART, RLENGTH)
            sub(/^[ \t;&|(){]/, "", tok); sub(/\+?=$/, "", tok)
            if (tok != "") assigned[tok] = 1
            rest = substr(rest, RSTART + RLENGTH)
          }
          if (match(ln, /(^|[ \t;])for[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
            tok = substr(ln, RSTART, RLENGTH); sub(/(^|[ \t;])for[ \t]+/, "", tok)
            assigned[tok] = 1
          }
          if (match(ln, /(^|[ \t;|])read[ \t]/)) {
            k = split(substr(ln, RSTART + RLENGTH), tok_a, /[ \t]+/)
            for (j = 1; j <= k; j++)
              if (tok_a[j] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) assigned[tok_a[j]] = 1
          }
          if (match(ln, /printf[ \t]+-v[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
            tok = substr(ln, RSTART, RLENGTH); sub(/printf[ \t]+-v[ \t]+/, "", tok)
            assigned[tok] = 1
          }

          # --- expansions -----------------------------------------------------
          rest = ln
          while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
            tok = substr(rest, RSTART, RLENGTH)
            pos = RSTART + RLENGTH
            name = tok; sub(/^\$\{?/, "", name)
            op = substr(rest, pos, 1)

            if (tok ~ /^\$\{/) {
              if (op == "?") {
                asserted[name] = 1                       # ${NAME?msg}
              } else if (op == ":") {
                op2 = substr(rest, pos + 1, 1)
                if (op2 == "?") asserted[name] = 1       # ${NAME:?msg}  <- the fix
                else if (op2 !~ /[-+=]/) record(name, i) # ${NAME:1:2} aborts if unset
                # ${NAME:-d} ${NAME:+a} ${NAME:=d} are unset-tolerant
              } else if (op ~ /[-+=]/) {
                # ${NAME-d} ${NAME+a} — unset-tolerant
              } else {
                record(name, i)                          # ${NAME} ${NAME#x} ${NAME[0]}
              }
            } else {
              record(name, i)                            # $NAME
            }
            rest = substr(rest, pos)
          }
        }

        for (name in refs) {
          if (name in assigned) { if (verbose) printf "  [ok]   %s assigned in the body\n", name; continue }
          if (name in asserted) { if (verbose) printf "  [ok]   %s asserted with ${%s:?...}\n", name, name; continue }
          if (name in allowed)  { if (verbose) printf "  [ok]   %s standard environment variable\n", name; continue }
          findings++
          printf "%s:%d: %s is expanded inside the quoted heredoc %s (opened at line %d) but is never set in it.\n",
            FILE, refs[name], name, delim, open_line
          printf "::error file=%s,line=%d::%s leaks out of the quoted heredoc %s. The generated script receives the literal text $%s and aborts under set -u. Pass it in explicitly and assert it with : \"${%s:?...}\".\n",
            FILE, refs[name], name, delim, name, name
        }

        in_doc = 0; body_n = 0
      }

      function record(name, i) {
        if (!(name in refs)) refs[name] = body_lineno[i]
      }
    ' "$file"
  )" && rc=0 || rc=$?

  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    n=$(printf '%s\n' "$out" | grep -c 'is expanded inside the quoted heredoc' || true)
    findings_total=$((findings_total + n))
  fi
  [ "${rc:-0}" -eq 0 ] || status=1
done

if [ "$status" -ne 0 ]; then
  echo ""
  echo "check-heredoc-vars.sh: FAILED — ${findings_total} variable(s) leak out of a quoted heredoc."
  echo "  Why this breaks: the quotes suppress expansion, so the generated script receives"
  echo "    the literal text \$NAME, and it usually runs in a fresh login shell (su -,"
  echo "    sudo -i) that does not inherit the caller's variables. Under set -u it aborts."
  echo "  How to fix: pass the value in explicitly, for example"
  echo "    su - box -c \"NODE_MAJOR=\$NODE_MAJOR bash /tmp/box-measure.sh\""
  echo "  and assert it at the top of the generated script:"
  echo "    : \"\${NODE_MAJOR:?must be passed in by the parent script}\""
  exit 1
fi

echo "check-heredoc-vars.sh: OK — no variable leaks out of a quoted heredoc (${#FILES[@]} file(s) checked)."
