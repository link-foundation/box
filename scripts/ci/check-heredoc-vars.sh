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
# looks right and is wrong. The quotes around the delimiter suppress expansion,
# so the generated file contains the literal characters $NODE_MAJOR, and `su -`
# starts a login shell that does not inherit the parent's variables. Under
# `set -u` the generated script dies with
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
#   ending in .sh/.bash, or a heredoc marked `# heredoc-script`), every
#   expansion in the body must be satisfied by one of:
#     1. an assignment inside the body;
#     2. an assertion inside the body, `: "${NAME:?...}"` — the intentional
#        injection, which also turns a future omission into a named error
#        instead of a bare line number;
#     3. a standard environment or shell variable (see ENV_ALLOWLIST);
#     4. an unset-tolerant form — ${NAME:-d}, ${NAME-d}, ${NAME:+a}, ${NAME:=d},
#        none of which can abort under set -u;
#     5. an `export NAME` in the parent, PROVIDED the generated script is not
#        run across an environment barrier. `su -`, `sudo -i`, `env -i` and
#        `ssh` all start from a clean environment, so exporting is not enough
#        there — and that is precisely the RC-1 shape.
#
# WHAT IT DOES NOT FLAG
#   Text the shell would never expand: single-quoted strings, backslash-escaped
#   \$NAME and comments, so `sed 's/\$FOO/x/'` is not reported. Heredocs whose
#   body is not a script (prose, JSON, config) are skipped, and so are unquoted
#   heredocs, which expand correctly at write time.
#
#   A comment line `# heredoc-vars: ignore` immediately above an opener
#   suppresses that one heredoc. It exists for deliberate counter-examples —
#   the fixtures in experiments/test-issue115-heredoc-unbound-vars.sh have to
#   contain the bug in order to prove the checker finds it. Suppressions are
#   counted and printed, so they cannot pile up unnoticed.
#
# USAGE
#   scripts/ci/check-heredoc-vars.sh [--verbose] [file ...]
#
#   With no files, checks every tracked *.sh in the repository.
#   --verbose (default off) prints every heredoc found and every expansion
#   classified, which is what you want when a finding looks wrong.
#
# EXIT
#   0 = clean, 1 = at least one leaked variable, 2 = usage error.

set -euo pipefail

VERBOSE=0
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    -v | --verbose)
      VERBOSE=1
      shift
      ;;
    -h | --help)
      sed -n '2,66p' "$0"
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "check-heredoc-vars.sh: unknown option $1" >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
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
suppressed_total=0
suppressed_files=""

for file in "${FILES[@]}"; do
  [ -f "$file" ] || continue
  # The file is read twice: pass 1 collects the parent's exports and every
  # command that crosses an environment barrier, pass 2 does the analysis.
  out="$(
    VERBOSE="$VERBOSE" ENV_ALLOWLIST="$ENV_ALLOWLIST" \
      awk -v FILE="$file" '
      BEGIN {
        verbose = (ENVIRON["VERBOSE"] == "1")
        n = split(ENVIRON["ENV_ALLOWLIST"], a, /[ \t\n]+/)
        for (i = 1; i <= n; i++) if (a[i] != "") allowed[a[i]] = 1
        in_doc = 0; findings = 0; barriers = 0
      }

      # ======================= pass 1: whole-file facts ======================
      NR == FNR {
        # export NAME / export NAME=value / declare -x NAME
        if (match($0, /(^|[ \t;&|(])(export|declare[ \t]+-x|typeset[ \t]+-x)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
          t = substr($0, RSTART, RLENGTH)
          sub(/.*[ \t]/, "", t)
          exported[t] = 1
        }
        # Commands that start from a clean environment. Exporting does not
        # survive these, so they are what makes a leak fatal.
        if ($0 !~ /^[ \t]*#/ &&
            $0 ~ /(^|[ \t;&|(])(su[ \t]+(-l?[ \t]|-[ \t]|-$)|su[ \t]+-|sudo[ \t]+(-i|--login)|env[ \t]+-i|ssh[ \t])/)
          barrier_line[++barriers] = $0
        next
      }

      # ======================= pass 2: the heredocs ==========================
      in_doc {
        stripped = $0; sub(/^[ \t]*/, "", stripped)
        if (stripped == delim) { finish(); next }
        body_line[++body_n] = $0
        body_lineno[body_n] = FNR
        next
      }

      {
        # A comment is not code. Without this, the worked example in this very
        # file(s header would be read as a real heredoc whose terminator never
        # arrives, swallowing the rest of the file.
        if ($0 ~ /^[ \t]*#/) {
          if ($0 ~ /heredoc-script/)              pending_script = 1
          if ($0 ~ /heredoc-vars:[ \t]*ignore/)   pending_ignore = 1
          next
        }

        # A quoted delimiter is what suppresses expansion; <<EOF is fine.
        if (match($0, /<<-?[ \t]*(\47[A-Za-z_][A-Za-z0-9_]*\47|"[A-Za-z_][A-Za-z0-9_]*")/)) {
          d = substr($0, RSTART, RLENGTH)
          sub(/^<<-?[ \t]*/, "", d)
          gsub(/[\47"]/, "", d)

          # Only bodies that become a shell script are checked; a quoted heredoc
          # holding prose, JSON or a config file is not a script and may
          # legitimately contain text that merely looks like a variable. The
          # redirection target may be quoted: cat > "$TMP/x.sh" <<(EOF(.
          target = ""
          if (match($0, /(>|>>|tee[ \t]+(-a[ \t]+)?)[ \t]*[\47"]?[^ \t\47"]*\.(sh|bash)[\47"]?([ \t]|$)/)) {
            target = substr($0, RSTART, RLENGTH)
            sub(/^(>|>>|tee[ \t]+(-a[ \t]+)?)[ \t]*/, "", target)
            gsub(/[\47" \t]/, "", target)
            sub(/.*\//, "", target)                     # basename
          }
          is_script = pending_script || (target != "")

          if (is_script && pending_ignore) {
            if (verbose) printf "  [heredoc] %s:%d opens %s (suppressed by # heredoc-vars: ignore)\n", FILE, FNR, d
            suppressed++
            skip_doc = 1; in_doc = 1; delim = d; open_line = FNR; body_n = 0
          } else if (is_script) {
            in_doc = 1; delim = d; open_line = FNR; body_n = 0
            doc_target = target
            if (verbose) printf "  [heredoc] %s:%d opens %s -> %s\n", FILE, open_line, d, (target ? target : "(marked)")
          } else if (verbose) {
            printf "  [heredoc] %s:%d opens %s (skipped: does not generate a .sh)\n", FILE, FNR, d
          }
        }
        pending_script = 0; pending_ignore = 0
      }

      END {
        if (in_doc) finish()
        if (suppressed > 0) printf "SUPPRESSED\t%s\t%d\n", FILE, suppressed
        exit (findings > 0 ? 1 : 0)
      }

      # ----------------------------------------------------------------------
      # Blank out every region the shell would not expand, so only real
      # expansions survive: single-quoted strings, backslash escapes, comments.
      # Quote state carries across lines, because a heredoc body is a script and
      # its strings may span lines.
      function strip(line,   out, i, c, prev) {
        out = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (in_sq) { if (c == "\47") in_sq = 0; out = out " "; continue }
          if (c == "\\") { out = out "  "; i++; continue }      # \$ is literal
          if (c == "\47" && !in_dq) { in_sq = 1; out = out " "; continue }
          if (c == "\"") { in_dq = !in_dq; out = out " "; continue }
          if (c == "#" && !in_dq) {
            prev = (i == 1) ? " " : substr(line, i - 1, 1)
            if (prev ~ /[ \t;&|(]/ || i == 1) return out       # rest is a comment
          }
          out = out c
        }
        return out
      }

      # Does the generated script run across an environment barrier? If it does,
      # an export in the parent is not enough.
      function crosses_barrier(   i) {
        if (doc_target == "") return 0
        for (i = 1; i <= barriers; i++)
          if (index(barrier_line[i], doc_target) > 0) return 1
        return 0
      }

      function finish(   i, ln, name, op, op2, rest, pos, tok, j, k, barrier, why) {
        if (skip_doc) { skip_doc = 0; in_doc = 0; body_n = 0; return }
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

          # --- expansions ------------------------------------------------------
          rest = ln
          while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
            tok = substr(rest, RSTART, RLENGTH)
            pos = RSTART + RLENGTH
            name = tok; sub(/^\$\{?/, "", name)
            op = substr(rest, pos, 1)

            if (tok ~ /^\$\{/) {
              if (op == "?") {
                asserted[name] = 1                        # ${NAME?msg}
              } else if (op == ":") {
                op2 = substr(rest, pos + 1, 1)
                if (op2 == "?") asserted[name] = 1        # ${NAME:?msg}  <- the fix
                else if (op2 !~ /[-+=]/) record(name, i)  # ${NAME:1:2} aborts if unset
              } else if (op ~ /[-+=]/) {
                # ${NAME-d} ${NAME+a} — unset-tolerant
              } else {
                record(name, i)                           # ${NAME} ${NAME#x} ${NAME[0]}
              }
            } else {
              record(name, i)                             # $NAME
            }
            rest = substr(rest, pos)
          }
        }

        barrier = crosses_barrier()

        for (name in refs) {
          if (name in assigned) { if (verbose) printf "  [ok]   %s assigned in the body\n", name; continue }
          if (name in asserted) { if (verbose) printf "  [ok]   %s asserted with ${%s:?...}\n", name, name; continue }
          if (name in allowed)  { if (verbose) printf "  [ok]   %s standard environment variable\n", name; continue }
          if ((name in exported) && !barrier) {
            if (verbose) printf "  [ok]   %s exported by the parent; the child inherits it\n", name
            continue
          }

          findings++
          why = (name in exported) \
            ? sprintf("The parent exports it, but %s is executed across an environment barrier (su -, sudo -i, env -i, ssh) that starts from a clean environment, so the export does not survive.", doc_target) \
            : "The generated script receives the literal text $" name " and aborts under set -u."
          printf "%s:%d: %s is expanded inside the quoted heredoc %s (opened at line %d) but is never set in it.\n",
            FILE, refs[name], name, delim, open_line
          printf "    %s\n", why
          printf "::error file=%s,line=%d::%s leaks out of the quoted heredoc %s. %s Pass it in explicitly and assert it with : \"${%s:?...}\".\n",
            FILE, refs[name], name, delim, why, name
        }

        in_doc = 0; body_n = 0; doc_target = ""
      }

      function record(name, i) {
        if (!(name in refs)) refs[name] = body_lineno[i]
      }
    ' "$file" "$file"
  )" && rc=0 || rc=$?

  if [ -n "$out" ]; then
    # SUPPRESSED lines are bookkeeping, not findings.
    while IFS=$'\t' read -r tag sup_file sup_n; do
      [ "$tag" = "SUPPRESSED" ] || continue
      suppressed_total=$((suppressed_total + sup_n))
      suppressed_files="$suppressed_files  $sup_file ($sup_n)\n"
    done < <(printf '%s\n' "$out" | grep '^SUPPRESSED' || true)

    body="$(printf '%s\n' "$out" | grep -v '^SUPPRESSED' || true)"
    [ -z "$body" ] || printf '%s\n' "$body"
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
  echo "    su - box -c \"env NODE_MAJOR='\$NODE_MAJOR' bash /tmp/box-measure.sh\""
  echo "  and assert it at the top of the generated script:"
  echo "    : \"\${NODE_MAJOR:?must be passed in by the parent script}\""
  exit 1
fi

echo "check-heredoc-vars.sh: OK — no variable leaks out of a quoted heredoc (${#FILES[@]} file(s) checked)."
if [ "$suppressed_total" -gt 0 ]; then
  echo "  ${suppressed_total} heredoc(s) suppressed with '# heredoc-vars: ignore':"
  printf "%b" "$suppressed_files"
fi
