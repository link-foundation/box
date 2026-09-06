#!/usr/bin/env bash
# Experiment script to test installation methods for new languages

set -euo pipefail

echo "Testing language installation methods..."
echo ""

# R Language
echo "==> Testing R installation..."
echo "Method: Install via apt package r-base"
echo "R is available in Ubuntu repositories as r-base package"
echo ""

# Swift
echo "==> Testing Swift installation..."
echo "Method: Download official Swift toolchain from swift.org"
echo "Swift provides official binaries for Ubuntu 24.04"
echo "Architecture-specific downloads needed (amd64/arm64)"
echo ""

# Ruby
echo "==> Testing Ruby installation..."
echo "Method: Use rbenv (Ruby version manager, similar to pyenv/nvm)"
echo "Alternative: rvm (Ruby Version Manager)"
echo "Recommended: rbenv for consistency with other version managers in the image"
echo ""

# Kotlin
echo "==> Testing Kotlin installation..."
echo "Method: Use SDKMAN (already installed for Java)"
echo "SDKMAN can install Kotlin compiler and tools"
echo "Command: sdk install kotlin"
echo ""

# Assembly
echo "==> Testing Assembly tools installation..."
echo "Method: Install via apt packages"
echo "GNU Assembler (as): Part of binutils (already installed with build-essential)"
echo "nasm: Available as apt package 'nasm'"
echo "llvm-mc: Part of llvm package (already installed)"
echo "FASM: Available as apt package 'fasm' or download from flatassembler.net"
echo ""

echo "Summary of installation approaches:"
echo "1. R: apt-get install r-base"
echo "2. Swift: Download from swift.org (architecture-specific)"
echo "3. Ruby: rbenv (version manager)"
echo "4. Kotlin: SDKMAN (already available)"
echo "5. Assembly:"
echo "   - GNU Assembler: Already installed (part of binutils)"
echo "   - nasm: apt-get install nasm"
echo "   - llvm-mc: Already installed (part of llvm)"
echo "   - FASM: apt-get install fasm"
echo ""

# Check what's already installed
echo "==> Checking already installed tools..."
echo ""

if command -v as &>/dev/null; then
    echo "✓ GNU Assembler (as): $(as --version | head -n1)"
else
    echo "✗ GNU Assembler (as): not found"
fi

if command -v llvm-mc &>/dev/null; then
    echo "✓ LLVM Machine Code Playground (llvm-mc): installed"
else
    echo "✗ llvm-mc: not found (may need explicit check)"
fi

if command -v nasm &>/dev/null; then
    echo "✓ NASM: $(nasm -v)"
else
    echo "✗ NASM: not installed"
fi

if command -v fasm &>/dev/null; then
    echo "✓ FASM: $(fasm 2>&1 | head -n1 || echo 'version check failed')"
else
    echo "✗ FASM: not installed"
fi

if command -v R &>/dev/null; then
    echo "✓ R: $(R --version | head -n1)"
else
    echo "✗ R: not installed"
fi

if command -v swift &>/dev/null; then
    echo "✓ Swift: $(swift --version | head -n1)"
else
    echo "✗ Swift: not installed"
fi

if command -v ruby &>/dev/null; then
    echo "✓ Ruby: $(ruby --version)"
else
    echo "✗ Ruby: not installed"
fi

if command -v kotlin &>/dev/null; then
    echo "✓ Kotlin: $(kotlin -version 2>&1 | head -n1)"
else
    echo "✗ Kotlin: not installed"
fi

echo ""
echo "Experiment complete!"
