#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

eval "$(shellspec - -c) exit 1"

ROOT="$(git rev-parse --show-toplevel)"
CLUSTER_NAME="test-attest"
WORK_DIR=""
TEST_IMAGE_DIGEST=""

# Push an image to localhost:5000, handling podman's TLS requirements.
push_local() {
    local image="$1"
    if docker push --help 2>&1 | grep -q -- '--tls-verify'; then
        docker push --tls-verify=false "${image}"
    else
        docker push "${image}"
    fi
}

Describe "create-test-result-attestation integration"
  SETUP_LOG="$(mktemp)"
  setup() {
    _setup_impl > "${SETUP_LOG}" 2>&1 || { cat "${SETUP_LOG}" >&2; return 1; }
  }

  _setup_impl() {
    for cmd in docker kind kubectl tkn oras yq; do
      if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: ${cmd} is required but not installed." >&2
        return 1
      fi
    done

    WORK_DIR="$(mktemp -d)"

    # --- Kind cluster (reuse if exists) ---
    kind get clusters -q | grep -q "${CLUSTER_NAME}" || {
      cat <<EOF | kind create cluster -q --name="${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        "service-node-port-range": "1-65535"
  extraPortMappings:
  - containerPort: 5000
    hostPort: 5000
    listenAddress: 127.0.0.1
    protocol: TCP
EOF
    } || { echo 'ERROR: Unable to create kind cluster'; return 1; }
    kubectl config use-context "kind-${CLUSTER_NAME}" > /dev/null \
      || { echo "ERROR: Failed to switch kubectl context to kind-${CLUSTER_NAME}"; return 1; }
    kubectl cluster-info 2>&1 || { echo 'ERROR: Failed to access the cluster'; return 1; }

    # --- Tekton Pipelines ---
    local tekton_version=v0.65.2
    kubectl apply -f "https://storage.googleapis.com/tekton-releases/pipeline/previous/${tekton_version}/release.yaml"
    kubectl -n tekton-pipelines wait deployment tekton-pipelines-controller --for=condition=Available --timeout=5m
    kubectl -n tekton-pipelines wait deployment tekton-pipelines-webhook --for=condition=Available --timeout=5m

    # --- Enable StepActions (required in Tekton v0.65.x) ---
    kubectl -n tekton-pipelines patch configmap feature-flags --type merge -p '{"data":{"enable-step-actions":"true"}}'

    # --- Namespace ---
    kubectl create namespace test --dry-run=client -o yaml | kubectl apply -f -
    kubectl config set-context --current --namespace=test
    local sa_timeout=60
    while ! kubectl get serviceaccount default 2> /dev/null; do
      sa_timeout=$((sa_timeout - 1))
      if [ "${sa_timeout}" -le 0 ]; then
        echo "ERROR: Timed out waiting for default serviceaccount" >&2
        return 1
      fi
      sleep 1
    done

    # --- In-cluster OCI registry ---
    kubectl create deployment registry --image=docker.io/registry:2.8.1 --port=5000 \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl create service nodeport registry --tcp=5000:5000 \
        --dry-run=client -o yaml \
        | kubectl patch -f - --type json --dry-run=client -o yaml \
            -p '[{"op":"add","path":"/spec/ports/0/nodePort","value":5000}]' \
        | kubectl apply -f -
    kubectl wait deployment registry --for=condition=Available --timeout=3m

    # --- Build step action image and push to in-cluster registry ---
    docker build -t localhost:5000/attest-test-result:test "${ROOT}"
    push_local localhost:5000/attest-test-result:test

    # --- Push a test image to attest against ---
    docker pull busybox:latest
    docker tag busybox:latest localhost:5000/test-image:latest
    push_local localhost:5000/test-image:latest
    TEST_IMAGE_DIGEST=$(curl -sI \
        -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
        http://localhost:5000/v2/test-image/manifests/latest \
        | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r\n')
    if [ -z "${TEST_IMAGE_DIGEST}" ]; then
      echo "ERROR: Could not get test image digest" >&2
      return 1
    fi
    echo "Test image digest: ${TEST_IMAGE_DIGEST}"

    # --- Apply StepAction (override image for local testing) ---
    yq '
      .spec.image = "localhost:5000/attest-test-result:test"
    ' "${ROOT}/stepactions/attest-test-result/0.1/attest-test-result.yaml" \
        | sed -e 's/oras attach /oras attach --plain-http /g' \
              -e 's/oras discover /oras discover --plain-http /g' \
        | kubectl apply -f -

    # --- Apply wrapper Task ---
    kubectl apply -f "${ROOT}/tests/integration/wrapper-task.yaml"
  }

  cleanup() {
    [ -z "${WORK_DIR}" ] || rm -rf "${WORK_DIR}"
    [ -z "${SETUP_LOG}" ] || rm -f "${SETUP_LOG}"
  }

  BeforeAll setup
  AfterAll cleanup

  It "creates and pushes a test-result attestation"
    When call tkn task start test-attest-wrapper \
        -p IMAGE_URL=registry:5000/test-image \
        -p IMAGE_DIGEST="${TEST_IMAGE_DIGEST}" \
        -p TEST_NAME=integration-test \
        -p 'TEST_OUTPUT={"result":"PASSED","successes":1,"failures":0,"warnings":0}' \
        --use-param-defaults \
        --timeout 5m \
        --showlog
    The status should be success
    The output should include "=== Attestation Complete ==="
    The taskrun should jq '.status.steps[0].results[] | select(.name=="TEST_OUTPUT_ARTIFACT_OUTPUTS").value | fromjson | .uri | test("registry:5000/test-image")'
    The taskrun should jq '.status.steps[0].results[] | select(.name=="TEST_OUTPUT_ARTIFACT_OUTPUTS").value | fromjson | .digest | test("^sha256:[a-f0-9]+$")'
  End

  It "attestation is discoverable from the registry"
    verify_attestation() {
      local image_ref="localhost:5000/test-image@${TEST_IMAGE_DIGEST}"
      local manifests
      manifests=$(oras discover "${image_ref}" -o json --plain-http 2>/dev/null \
          | jq '.manifests | length')
      echo "manifests_found=${manifests}"
      [ "${manifests}" -gt 0 ]
    }

    When call verify_attestation
    The status should be success
    The output should include "manifests_found="
  End

  It "creates attestation for FAILED test results"
    When call tkn task start test-attest-wrapper \
        -p IMAGE_URL=registry:5000/test-image \
        -p IMAGE_DIGEST="${TEST_IMAGE_DIGEST}" \
        -p TEST_NAME=failing-test \
        -p 'TEST_OUTPUT={"result":"FAILED","successes":0,"failures":3,"warnings":1}' \
        --use-param-defaults \
        --timeout 5m \
        --showlog
    The status should be success
    The output should include "=== Attestation Complete ==="
    The taskrun should jq '.status.steps[0].results[] | select(.name=="TEST_OUTPUT_ARTIFACT_OUTPUTS").value | fromjson | .uri | test("registry:5000/test-image")'
    The taskrun should jq '.status.steps[0].results[] | select(.name=="TEST_OUTPUT_ARTIFACT_OUTPUTS").value | fromjson | .digest | test("^sha256:[a-f0-9]+$")'
  End

  It "attestation has correct annotations"
    check_annotations() {
      local image_ref="localhost:5000/test-image@${TEST_IMAGE_DIGEST}"
      oras discover "${image_ref}" -o json --plain-http 2>/dev/null \
        | jq -r '.manifests[] | select(.annotations.testName == "integration-test") | .annotations'
    }

    When call check_annotations
    The status should be success
    The output should include '"testName": "integration-test"'
    The output should include '"predicateType": "https://in-toto.io/attestation/test-result/v0.1"'
    The output should include '"org.opencontainers.image.created":'
  End

  It "attestation predicate contains expected fields"
    check_predicate() {
      local image_ref="localhost:5000/test-image@${TEST_IMAGE_DIGEST}"
      local att_digest
      att_digest=$(oras discover "${image_ref}" -o json --plain-http 2>/dev/null \
        | jq -r '.manifests[] | select(.annotations.testName == "integration-test") | .digest')
      local att_ref="localhost:5000/test-image@${att_digest}"
      local blob_digest
      blob_digest=$(oras manifest fetch "${att_ref}" --plain-http 2>/dev/null \
        | jq -r '.layers[0].digest')
      oras blob fetch "${att_ref}" --descriptor "${blob_digest}" --plain-http --output - 2>/dev/null \
        | jq '.predicate'
    }

    When call check_predicate
    The status should be success
    The output should include '"result":'
    The output should include '"timestamp":'
    The output should include '"configuration":'
    The output should include '"successes":'
    The output should include '"failures":'
    The output should include '"warnings":'
    The output should include '"output":'
  End
End
