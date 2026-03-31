#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v shellspec &> /dev/null; then
    echo "shellspec not found, installing..."
    curl -fsSL https://git.io/shellspec | sh -s -- --yes
fi

readarray -d '' SPEC_DIRS < <(find "${ROOT}" -name spec -type d -print0)

if [ ${#SPEC_DIRS[@]} -eq 0 ]; then
    echo "No spec directories found."
    exit 0
fi

BIN_BASH=$(which bash)
FAILURES=0

for SPEC_DIR in "${SPEC_DIRS[@]}"; do
    [[ -z "${SPEC_DIR}" ]] && continue
    echo -e "\n=== Running tests in \033[1m${SPEC_DIR}\033[0m ==="
    PARAMS=(--chdir "${SPEC_DIR}" --shell "${BIN_BASH}")
    [[ -n "${GITHUB_ACTIONS:-}" ]] && PARAMS+=(--format tap)
    if ! shellspec "${PARAMS[@]}"; then
        FAILURES=$((FAILURES + 1))
    fi
done

if [ "${FAILURES}" -gt 0 ]; then
    echo -e "\n\033[31m${FAILURES} spec suite(s) failed.\033[0m"
    exit 1
fi

echo -e "\n\033[32mAll spec suites passed.\033[0m"
