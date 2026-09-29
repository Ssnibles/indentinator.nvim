#!/usr/bin/env sh
# Run all indentinator.nvim headless test suites.
set -eu

cd "$(dirname "$0")/.."

NVIM="${NVIM:-nvim}"

for suite in tests/test_*.lua
do
  echo "=== $suite ==="
  "$NVIM" --headless -u NONE -c "set rtp+=." -c "luafile $suite" -c "qa!"
done

echo "All test suites passed."
