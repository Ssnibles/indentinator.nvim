#!/usr/bin/env sh
# Run all indentinator.nvim headless test suites.
#
# `nvim -l script.lua` exits non-zero when the suite errors, unlike
# `-c "luafile script" -c "qa!"`, which always exits 0 and would let a broken
# suite masquerade as a pass in CI.
set -eu

cd "$(dirname "$0")/.."

NVIM="${NVIM:-nvim}"

for suite in tests/test_*.lua
do
  echo "=== $suite ==="
  "$NVIM" --headless -u NONE --cmd "set rtp+=." -l "$suite"
done

echo "All test suites passed."
