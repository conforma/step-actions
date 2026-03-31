#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

for cmd in shellspec yq jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: ${cmd} is not installed or not in PATH." >&2
    exit 1
  fi
done

eval "$(shellspec - -c) exit 1"

stepaction_path=attest-test-result.yaml

if [[ -f "../${stepaction_path}" ]]; then
    stepaction_path="../${stepaction_path}"
fi

extract_script() {
  local script
  script="$(mktemp)"

  # Extract the script from the StepAction YAML, replacing the Tekton
  # result path variable with a shell variable reference so the test
  # can point it at a temp file.
  yq -r '.spec.script' "${stepaction_path}" \
      | sed 's|$(step.results.TEST_OUTPUT_ARTIFACT_OUTPUTS.path)|${RESULT_FILE}|g' \
      > "${script}"

  chmod +x "${script}"
  echo "${script}"
}

cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT

attest_script="$(extract_script)"
cleanup+=("${attest_script}")

testdir() {
    testdir="$(mktemp -d)" && cleanup+=("${testdir}") && cd "${testdir}"
    export RESULT_FILE="${testdir}/result.json"
    AfterEach 'rm -rf "$testdir"'
}

default_env() {
    export IMAGE_URL="quay.io/org/image"
    export IMAGE_DIGEST="sha256:abcdef1234567890"
    export TEST_NAME="integration-test"
    export TEST_OUTPUT='{"result":"PASSED","successes":1,"failures":0,"warnings":0}'
    export PREDICATE_TYPE="https://in-toto.io/attestation/test-result/v0.1"
    export UPLOAD_TLOG="false"
    export COSIGN_KEY_PATH="${testdir}/cosign.key"
    touch "${COSIGN_KEY_PATH}"
    unset REKOR_URL 2>/dev/null || true
}

# Helpers for jq assertions via `should satisfy`.
# ShellSpec passes the subject via $SHELLSPEC_SUBJECT; positional args
# come from the assertion line after the function name.
jq_field_eq() {
    [ "$(echo "${SHELLSPEC_SUBJECT}" | jq -r "$1")" = "$2" ]
}

jq_num_eq() {
    [ "$(echo "${SHELLSPEC_SUBJECT}" | jq "$1")" = "$2" ]
}


Describe "COSIGN_KEY_PATH validation"
    BeforeEach testdir

    It "fails when COSIGN_KEY_PATH is unset"
        default_env
        unset COSIGN_KEY_PATH

        When call "${attest_script}"
        The status should be failure
        The output should include "ERROR: Cosign key not found"
        The contents of file "${RESULT_FILE}" should equal '{"uri":"","digest":""}'
    End

    It "fails when COSIGN_KEY_PATH is empty"
        default_env
        export COSIGN_KEY_PATH=""

        When call "${attest_script}"
        The status should be failure
        The output should include "ERROR: Cosign key not found"
        The contents of file "${RESULT_FILE}" should equal '{"uri":"","digest":""}'
    End

    It "fails when cosign key file does not exist"
        default_env
        export COSIGN_KEY_PATH="${testdir}/nonexistent.key"

        When call "${attest_script}"
        The status should be failure
        The output should include "ERROR: Cosign key not found"
        The contents of file "${RESULT_FILE}" should equal '{"uri":"","digest":""}'
    End
End


Describe "predicate construction"
    BeforeEach testdir

    It "includes all fields from test output"
        default_env
        Mock cosign
            cosign_args="$*"
            %preserve cosign_args
            prev=""
            for arg in "$@"; do
                if [ "$prev" = "--predicate" ]; then
                    cp "$arg" captured-predicate.json 2>/dev/null || true
                    break
                fi
                prev="$arg"
            done
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The file "captured-predicate.json" should be exist
        The contents of file "captured-predicate.json" should satisfy jq_field_eq '.result' 'PASSED'
        The contents of file "captured-predicate.json" should satisfy jq_field_eq '.configuration[0].name' 'integration-test'
        The contents of file "captured-predicate.json" should satisfy jq_field_eq '.timestamp' '2025-01-15T12:00:00Z'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.successes' '1'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.failures' '0'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.warnings' '0'
    End

    It "defaults missing result to UNKNOWN and counters to 0"
        default_env
        export TEST_OUTPUT='{}'
        Mock cosign
            prev=""
            for arg in "$@"; do
                if [ "$prev" = "--predicate" ]; then
                    cp "$arg" captured-predicate.json 2>/dev/null || true
                    break
                fi
                prev="$arg"
            done
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "captured-predicate.json" should satisfy jq_field_eq '.result' 'UNKNOWN'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.successes' '0'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.failures' '0'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.warnings' '0'
    End

    It "embeds full test output in the output field"
        default_env
        Mock cosign
            prev=""
            for arg in "$@"; do
                if [ "$prev" = "--predicate" ]; then
                    cp "$arg" captured-predicate.json 2>/dev/null || true
                    break
                fi
                prev="$arg"
            done
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "captured-predicate.json" should satisfy jq_field_eq '.output.result' 'PASSED'
        The contents of file "captured-predicate.json" should satisfy jq_num_eq '.output.successes' '1'
    End
End


Describe "cosign arguments"
    BeforeEach testdir

    It "passes --tlog-upload=false when tlog is disabled"
        default_env
        export UPLOAD_TLOG="false"
        Mock cosign
            cosign_args="$*"
            %preserve cosign_args
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The variable cosign_args should include '--tlog-upload=false'
        The variable cosign_args should include '--new-bundle-format'
        The variable cosign_args should include '--key'
    End

    It "passes --rekor-url when tlog enabled with REKOR_URL"
        default_env
        export UPLOAD_TLOG="true"
        export REKOR_URL="https://rekor.example.com"
        Mock cosign
            cosign_args="$*"
            %preserve cosign_args
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The variable cosign_args should include '--rekor-url'
        The variable cosign_args should include 'https://rekor.example.com'
        The variable cosign_args should not include '--tlog-upload=false'
    End

    It "omits --rekor-url when tlog enabled without REKOR_URL"
        default_env
        export UPLOAD_TLOG="true"
        Mock cosign
            cosign_args="$*"
            %preserve cosign_args
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The variable cosign_args should not include '--rekor-url'
        The variable cosign_args should not include '--tlog-upload=false'
    End

    It "targets the correct image reference"
        default_env
        Mock cosign
            cosign_args="$*"
            %preserve cosign_args
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:mock-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The variable cosign_args should include 'quay.io/org/image@sha256:abcdef1234567890'
    End
End


Describe "oras discover"
    BeforeEach testdir

    It "uses digest from primary discover with artifact-type filter"
        default_env
        Mock cosign
            :
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:primary-digest"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "${RESULT_FILE}" should satisfy jq_field_eq '.digest' 'sha256:primary-digest'
    End

    It "falls back to unfiltered discover when primary returns empty"
        default_env
        Mock cosign
            :
        End
        Mock oras
            if echo "$*" | grep -q -- "--artifact-type"; then
                echo '{"manifests":[]}'
            else
                echo '{"manifests":[{"digest":"sha256:fallback-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "${RESULT_FILE}" should satisfy jq_field_eq '.digest' 'sha256:fallback-digest'
    End

    It "fails when no attestation digest can be discovered"
        default_env
        Mock cosign
            :
        End
        Mock oras
            echo '{"manifests":[]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be failure
        The output should include "ERROR: Could not discover attestation digest"
        The contents of file "${RESULT_FILE}" should equal '{"uri":"","digest":""}'
    End
End


Describe "result output"
    BeforeEach testdir

    It "writes JSON with correct uri and digest"
        default_env
        Mock cosign
            :
        End
        Mock oras
            echo '{"manifests":[{"digest":"sha256:attested-abc123"}]}'
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "${RESULT_FILE}" should satisfy jq_field_eq '.uri' 'quay.io/org/image'
        The contents of file "${RESULT_FILE}" should satisfy jq_field_eq '.digest' 'sha256:attested-abc123'
    End
End
