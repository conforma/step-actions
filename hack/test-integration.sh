#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for cmd in docker kind kubectl tkn oras shellspec yq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: ${cmd} is required but not installed." >&2
        exit 1
    fi
done

echo "=== Running integration tests ==="
echo "This will create a Kind cluster, install Tekton, and run real TaskRuns."
echo ""

shellspec --chdir "${ROOT}/tests/integration" --shell "$(which bash)"
