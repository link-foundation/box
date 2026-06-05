#!/usr/bin/env bash
# Verify the installation script syntax before building Docker image

set -euo pipefail

cd "$(dirname "$0")/.."
INSTALL_SCRIPT="scripts/ubuntu-24-server-install.sh"

echo "==> Verifying installation script syntax..."
echo ""

# Check if the script is valid bash syntax
if bash -n "$INSTALL_SCRIPT"; then
    echo "✓ Installation script syntax is valid"
else
    echo "✗ Installation script has syntax errors"
    exit 1
fi

# Check for common issues
echo ""
echo "==> Checking for common issues..."

# Check if all new sections are present
if grep -q "Install Assembly Tools" "$INSTALL_SCRIPT"; then
    echo "✓ Assembly tools section found"
else
    echo "✗ Assembly tools section missing"
fi

if grep -q "Install R Language" "$INSTALL_SCRIPT"; then
    echo "✓ R language section found"
else
    echo "✗ R language section missing"
fi

if grep -q "Ruby (via rbenv)" "$INSTALL_SCRIPT"; then
    echo "✓ Ruby/rbenv section found"
else
    echo "✗ Ruby/rbenv section missing"
fi

if grep -q "Swift ---" "$INSTALL_SCRIPT"; then
    echo "✓ Swift section found"
else
    echo "✗ Swift section missing"
fi

if grep -q "Kotlin (via SDKMAN)" "$INSTALL_SCRIPT"; then
    echo "✓ Kotlin section found"
else
    echo "✗ Kotlin section missing"
fi

# Check verification sections
if grep -q "Assembly Tools:" "$INSTALL_SCRIPT"; then
    echo "✓ Assembly verification section found"
else
    echo "✗ Assembly verification section missing"
fi

echo ""
echo "All checks passed!"
