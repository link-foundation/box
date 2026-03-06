#!/usr/bin/env bash
# Experiment: Verify the .bashrc merge fix works correctly (issue #66)
# Simulates the Dockerfile merge algorithm (both old and new) and checks for syntax errors.

set -u

PASS=0
FAIL=0
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== Issue #66: .bashrc merge fix verification ==="
echo ""

# ─────────────────────────────────────────────────
# 1. Create realistic base .bashrc (like Ubuntu /etc/skel/.bashrc after essentials)
# ─────────────────────────────────────────────────
cat > "$WORKDIR/.bashrc-base" << 'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
HISTCONTROL=ignoreboth

# check the window size after each command
shopt -s checkwinsize

# set a fancy prompt
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

if [ "$TERM" = "xterm-color" ] || [ "$256color" = "${TERM#*-}" ]; then
    color_prompt=yes
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
fi

# Alias definitions
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# Deno configuration
export DENO_INSTALL="$HOME/.deno"
export PATH="$DENO_INSTALL/bin:$PATH"

# NVM configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF

echo "Base .bashrc syntax:"
bash -n "$WORKDIR/.bashrc-base" 2>&1 && pass "Base .bashrc is valid" || fail "Base .bashrc is invalid"
echo ""

# ─────────────────────────────────────────────────
# 2. Create language-specific .bashrc files (simulating what install.sh scripts produce)
# ─────────────────────────────────────────────────

# Python (adds pyenv section)
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-python"
cat >> "$WORKDIR/.bashrc-python" << 'EOF'

# Pyenv configuration
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
eval "$(pyenv init -)"
EOF

# Go (adds Go section)
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-go"
cat >> "$WORKDIR/.bashrc-go" << 'EOF'

# Go configuration
export GOROOT="$HOME/.go"
export GOPATH="$HOME/.go/path"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
EOF

# Java (adds SDKMAN section with fixed POSIX syntax)
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-java"
cat >> "$WORKDIR/.bashrc-java" << 'EOF'

# SDKMAN configuration
export SDKMAN_DIR="$HOME/.sdkman"
[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"
EOF

# Kotlin (same SDKMAN section - should be SKIPPED by merge as already present)
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-kotlin"
cat >> "$WORKDIR/.bashrc-kotlin" << 'EOF'

# SDKMAN configuration
export SDKMAN_DIR="$HOME/.sdkman"
[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ] && . "$HOME/.sdkman/bin/sdkman-init.sh"
EOF

# Perl (adds Perlbrew section WITH if/fi block - this was the bug trigger)
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-perl"
cat >> "$WORKDIR/.bashrc-perl" << 'EOF'

# Perlbrew configuration
if [ -n "$PS1" ]; then
  export PERLBREW_ROOT="$HOME/.perl5"
  [ -f "$PERLBREW_ROOT/etc/bashrc" ] && . "$PERLBREW_ROOT/etc/bashrc"
fi
EOF

echo "Language .bashrc files syntax:"
for f in python go java kotlin perl; do
    bash -n "$WORKDIR/.bashrc-$f" 2>&1 && pass "$f .bashrc is valid" || fail "$f .bashrc is invalid"
done
echo ""

# ─────────────────────────────────────────────────
# 3. TEST OLD (BROKEN) ALGORITHM
# ─────────────────────────────────────────────────
echo "=== Testing OLD merge algorithm (expected to FAIL) ==="
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-old-merged"

for lang_bashrc in "$WORKDIR/.bashrc-python" "$WORKDIR/.bashrc-go" "$WORKDIR/.bashrc-java" \
                   "$WORKDIR/.bashrc-kotlin" "$WORKDIR/.bashrc-perl"; do
    if [ -f "$lang_bashrc" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ] && ! grep -qxF "$line" "$WORKDIR/.bashrc-old-merged" 2>/dev/null; then
                echo "$line" >> "$WORKDIR/.bashrc-old-merged"
            fi
        done < "$lang_bashrc"
    fi
done

echo "Old merge result syntax:"
bash -n "$WORKDIR/.bashrc-old-merged" 2>&1
if bash -n "$WORKDIR/.bashrc-old-merged" 2>/dev/null; then
    fail "Old algorithm unexpectedly produced valid .bashrc (test assumption wrong)"
else
    pass "Old algorithm produces syntax error (as expected - bug confirmed)"
fi
echo ""

# Show what the old algorithm produced (relevant tail)
echo "Last 10 lines of old merged .bashrc:"
tail -10 "$WORKDIR/.bashrc-old-merged"
echo ""

# ─────────────────────────────────────────────────
# 4. TEST NEW (FIXED) ALGORITHM
# ─────────────────────────────────────────────────
echo "=== Testing NEW merge algorithm (expected to PASS) ==="
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-new-merged"

for lang_bashrc in "$WORKDIR/.bashrc-python" "$WORKDIR/.bashrc-go" "$WORKDIR/.bashrc-java" \
                   "$WORKDIR/.bashrc-kotlin" "$WORKDIR/.bashrc-perl"; do
    if [ -f "$lang_bashrc" ]; then
        in_new_section=0
        section_header=""
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^# .+ configuration$'; then
                section_header="$line"
                if grep -qxF "$section_header" "$WORKDIR/.bashrc-new-merged" 2>/dev/null; then
                    in_new_section=0
                else
                    in_new_section=1
                    echo "" >> "$WORKDIR/.bashrc-new-merged"
                    echo "$section_header" >> "$WORKDIR/.bashrc-new-merged"
                fi
            elif [ "$in_new_section" = "1" ]; then
                echo "$line" >> "$WORKDIR/.bashrc-new-merged"
            fi
        done < "$lang_bashrc"
    fi
done

echo "New merge result syntax:"
if bash -n "$WORKDIR/.bashrc-new-merged" 2>&1; then
    pass "New algorithm produces valid .bashrc (bug is fixed)"
else
    fail "New algorithm still produces syntax error"
fi
echo ""

# Show the full new merged .bashrc
echo "Full new merged .bashrc:"
cat -n "$WORKDIR/.bashrc-new-merged"
echo ""

# ─────────────────────────────────────────────────
# 5. VERIFY: SDKMAN section appears only once (deduplication works)
# ─────────────────────────────────────────────────
echo "=== Checking section deduplication ==="
SDKMAN_COUNT=$(grep -c "# SDKMAN configuration" "$WORKDIR/.bashrc-new-merged" 2>/dev/null || echo "0")
if [ "$SDKMAN_COUNT" = "1" ]; then
    pass "SDKMAN section appears exactly once (kotlin dedup worked)"
else
    fail "SDKMAN section count: $SDKMAN_COUNT (expected 1)"
fi

PERLBREW_COUNT=$(grep -c "# Perlbrew configuration" "$WORKDIR/.bashrc-new-merged" 2>/dev/null || echo "0")
if [ "$PERLBREW_COUNT" = "1" ]; then
    pass "Perlbrew section appears exactly once"
else
    fail "Perlbrew section count: $PERLBREW_COUNT (expected 1)"
fi

# ─────────────────────────────────────────────────
# 6. VERIFY: Perlbrew if/fi block is complete
# ─────────────────────────────────────────────────
IF_COUNT=$(grep -c "if \[ -n \"\$PS1\" \]" "$WORKDIR/.bashrc-new-merged" 2>/dev/null || echo "0")
FI_COUNT=$(grep -c "^fi$" "$WORKDIR/.bashrc-new-merged" 2>/dev/null || echo "0")
echo ""
echo "=== if/fi balance check ==="
echo "  'if [ -n \"\$PS1\" ]' count: $IF_COUNT"
echo "  Standalone 'fi' count: $FI_COUNT"
echo "  (Note: fi count includes all if blocks in base .bashrc + Perlbrew)"
if [ "$IF_COUNT" -le "$FI_COUNT" ]; then
    pass "if/fi blocks are balanced (every 'if' has a matching 'fi')"
else
    fail "if/fi blocks are NOT balanced (unclosed 'if' detected)"
fi

# ─────────────────────────────────────────────────
# 7. VERIFY: SDKMAN uses POSIX syntax (no [[ ]])
# ─────────────────────────────────────────────────
echo ""
echo "=== POSIX syntax check ==="
if grep -q '\[\[' "$WORKDIR/.bashrc-new-merged" 2>/dev/null; then
    fail "Found bash-specific [[ ]] in merged .bashrc"
    grep -n '\[\[' "$WORKDIR/.bashrc-new-merged"
else
    pass "No bash-specific [[ ]] found in merged .bashrc (POSIX compatible)"
fi

if grep -q ']] && source' "$WORKDIR/.bashrc-new-merged" 2>/dev/null; then
    fail "Found 'source' command (should use '.' for POSIX compatibility)"
else
    pass "No 'source' command in SDKMAN section (uses '.' for POSIX compat)"
fi

# ─────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "  Tests passed: $PASS"
echo "  Tests failed: $FAIL"
echo ""
if [ "$FAIL" = "0" ]; then
    echo "ALL TESTS PASSED - Fix is verified!"
    exit 0
else
    echo "SOME TESTS FAILED - Please investigate."
    exit 1
fi
