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


Describe "in-toto statement construction"
    BeforeEach testdir

    It "builds a complete in-toto statement with all fields"
        default_env
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                # Capture the statement file passed to oras attach
                for arg in "$@"; do
                    # The statement file is the arg matching *:application/json
                    case "$arg" in
                        *:application/json)
                            cp "${arg%%:*}" captured-statement.json 2>/dev/null || true
                            ;;
                    esac
                done
            else
                echo '{"referrers":[{"digest":"sha256:mock-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The file "captured-statement.json" should be exist
        # Envelope fields
        The contents of file "captured-statement.json" should satisfy jq_field_eq '._type' 'https://in-toto.io/Statement/v0.1'
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.predicateType' 'https://in-toto.io/attestation/test-result/v0.1'
        # Subject
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.subject[0].name' 'quay.io/org/image'
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.subject[0].digest.sha256' 'abcdef1234567890'
        # Predicate
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.predicate.result' 'PASSED'
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.predicate.configuration[0].name' 'integration-test'
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.predicate.timestamp' '2025-01-15T12:00:00Z'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.successes' '1'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.failures' '0'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.warnings' '0'
    End

    It "defaults missing result to UNKNOWN and counters to 0"
        default_env
        export TEST_OUTPUT='{}'
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                for arg in "$@"; do
                    case "$arg" in
                        *:application/json)
                            cp "${arg%%:*}" captured-statement.json 2>/dev/null || true
                            ;;
                    esac
                done
            else
                echo '{"referrers":[{"digest":"sha256:mock-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.predicate.result' 'UNKNOWN'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.successes' '0'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.failures' '0'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.warnings' '0'
    End

    It "embeds full test output in the output field"
        default_env
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                for arg in "$@"; do
                    case "$arg" in
                        *:application/json)
                            cp "${arg%%:*}" captured-statement.json 2>/dev/null || true
                            ;;
                    esac
                done
            else
                echo '{"referrers":[{"digest":"sha256:mock-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "captured-statement.json" should satisfy jq_field_eq '.predicate.output.result' 'PASSED'
        The contents of file "captured-statement.json" should satisfy jq_num_eq '.predicate.output.successes' '1'
    End
End


Describe "oras attach arguments"
    BeforeEach testdir

    It "attaches with correct artifact type and annotations"
        default_env
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                oras_args="$*"
                %preserve oras_args
            else
                echo '{"referrers":[{"digest":"sha256:mock-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The variable oras_args should include '--artifact-type'
        The variable oras_args should include 'application/vnd.in-toto+json'
        The variable oras_args should include 'predicateType=https://in-toto.io/attestation/test-result/v0.1'
        The variable oras_args should include 'testName=integration-test'
        The variable oras_args should include 'org.opencontainers.image.created=2025-01-15T12:00:00Z'
    End

    It "targets the correct image reference"
        default_env
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                oras_args="$*"
                %preserve oras_args
            else
                echo '{"referrers":[{"digest":"sha256:mock-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The variable oras_args should include 'quay.io/org/image@sha256:abcdef1234567890'
    End
End


Describe "oras discover"
    BeforeEach testdir

    It "uses digest from discover with artifact-type filter"
        default_env
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                :
            else
                echo '{"referrers":[{"digest":"sha256:primary-digest"}]}'
            fi
        End
        Mock date
            echo "2025-01-15T12:00:00Z"
        End

        When call "${attest_script}"
        The status should be success
        The output should include "=== Attestation Complete ==="
        The contents of file "${RESULT_FILE}" should satisfy jq_field_eq '.digest' 'sha256:primary-digest'
    End

    It "fails when no attestation digest can be discovered"
        default_env
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                :
            else
                echo '{"manifests":[]}'
            fi
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
        Mock select-oci-auth
            echo '{"auths":{"quay.io":{"auth":"dGVzdDp0ZXN0"}}}'
        End
        Mock oras
            if echo "$*" | grep -q "attach"; then
                :
            else
                echo '{"referrers":[{"digest":"sha256:attested-abc123"}]}'
            fi
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
