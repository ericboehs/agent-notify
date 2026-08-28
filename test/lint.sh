#!/usr/bin/env bash

# Shellcheck every tracked shell script.
# Usage: bash test/lint.sh [--list]
#
# Discovery is by shebang rather than by a hardcoded list or a *.sh glob:
# bin/agent-notify and friends have no extension, and a new script should be
# covered the moment it is committed rather than when someone remembers to add
# it here.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if ! command -v shellcheck >/dev/null; then
  echo -e "${RED}❌ shellcheck is not on PATH${NC}" >&2
  exit 1
fi

scripts=()
while IFS= read -r file; do
  [ -f "$file" ] || continue
  shebang="$(head -1 "$file" 2>/dev/null || true)"
  case "$shebang" in
    '#!'*bash* | '#!'*/bin/sh | '#!'*env\ sh) scripts+=("$file") ;;
  esac
done < <(git ls-files)

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${scripts[@]}"
  exit 0
fi

# "Nothing to check" must not read as success: a shebang convention change or a
# move out of git would otherwise print a green check for doing nothing.
if [ ${#scripts[@]} -eq 0 ]; then
  echo -e "${RED}❌ no shell scripts found to check${NC}" >&2
  exit 1
fi

echo "Checking ${#scripts[@]} scripts..."
if shellcheck "${scripts[@]}"; then
  echo -e "${GREEN}✅ shellcheck clean${NC}"
else
  echo -e "${RED}❌ shellcheck found problems${NC}" >&2
  exit 1
fi
