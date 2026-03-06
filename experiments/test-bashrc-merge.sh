#!/usr/bin/env bash
# Experiment: Reproduce the .bashrc merge bug (issue #66)
# This simulates what the Dockerfile merge algorithm does and shows the syntax error

set -u

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "=== Simulating .bashrc merge bug ==="
echo ""

# Create a base .bashrc with some fi lines (simulating Ubuntu's /etc/skel/.bashrc)
cat > "$WORKDIR/.bashrc-base" << 'BASHRC_BASE'
# Base .bashrc (simulating Ubuntu /etc/skel/.bashrc)
# if block 1
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
  debian_chroot=$(cat /etc/debian_chroot)
fi

# if block 2
if [ "$TERM" = "xterm-color" ] || [ "$TERM" = "256color" ]; then
  color_prompt=yes
fi

# NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# SDKMAN
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
BASHRC_BASE

echo "Base .bashrc (valid):"
bash -n "$WORKDIR/.bashrc-base" 2>&1 && echo "  -> VALID" || echo "  -> INVALID"
echo ""

# Create perl's .bashrc (same base plus Perlbrew block)
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-perl"
cat >> "$WORKDIR/.bashrc-perl" << 'PERL_SECTION'

# Perlbrew configuration
if [ -n "$PS1" ]; then
  export PERLBREW_ROOT="$HOME/.perl5"
  [ -f "$PERLBREW_ROOT/etc/bashrc" ] && source "$PERLBREW_ROOT/etc/bashrc"
fi
PERL_SECTION

echo "Perl .bashrc (valid):"
bash -n "$WORKDIR/.bashrc-perl" 2>&1 && echo "  -> VALID" || echo "  -> INVALID"
echo ""

# Now simulate the merge algorithm
echo "=== Running merge algorithm ==="
cp "$WORKDIR/.bashrc-base" "$WORKDIR/.bashrc-merged"

# Process perl's .bashrc (append unique lines, skip blank lines)
while IFS= read -r line; do
  if [ -n "$line" ] && ! grep -qxF "$line" "$WORKDIR/.bashrc-merged" 2>/dev/null; then
    echo "$line" >> "$WORKDIR/.bashrc-merged"
  fi
done < "$WORKDIR/.bashrc-perl"

echo ""
echo "Merged .bashrc content:"
cat -n "$WORKDIR/.bashrc-merged"
echo ""

echo "Merged .bashrc syntax check:"
bash -n "$WORKDIR/.bashrc-merged" 2>&1 && echo "  -> VALID" || echo "  -> SYNTAX ERROR (bug reproduced!)"
echo ""

# Show which fi was deduplicated
echo "=== Showing the fi deduplication issue ==="
echo "Lines from perl .bashrc that were skipped (already in base):"
while IFS= read -r line; do
  if [ -n "$line" ] && grep -qxF "$line" "$WORKDIR/.bashrc-base" 2>/dev/null; then
    echo "  SKIPPED: '$line'"
  fi
done < "$WORKDIR/.bashrc-perl"

