# create-test-result-attestation

Creates and pushes an in-toto test-result attestation to a container registry using cosign. Signs with a cosign key provided by the parent Task's workspace.

This implements the attestation pattern described in ADR-38 for reusable test result attestations.

## Parameters

| name | description | default value | required |
|------|-------------|---------------|----------|
| image-url | Image URL without digest (e.g. quay.io/org/image) | | true |
| image-digest | Image digest (sha256:...) | | true |
| test-name | Name of the test (e.g. integration-test, clair-scan) | | true |
| test-output | JSON test results to include in the attestation predicate | | true |
| cosign-key-path | Path to the cosign private key file for signing | | true |
| predicate-type | In-toto predicate type URI | `https://in-toto.io/attestation/test-result/v0.1` | false |
| upload-tlog | Upload to Sigstore transparency log | `"false"` | false |

## Results

| name | description |
|------|-------------|
| TEST_OUTPUT_ARTIFACT_OUTPUTS | JSON object with `uri` and `digest` fields referencing the pushed attestation. Tekton Chains uses this for SLSA provenance. |

## Signing

The parent Task must mount a `cosign-keys` workspace containing the signing key and pass the path via the `cosign-key-path` param:

```yaml
params:
  - name: cosign-key-path
    value: $(workspaces.cosign-keys.path)/cosign.key
```

If the key file is not found at the specified path, the step exits with an error and writes empty results.

## Usage

The parent Task should map the StepAction results into a Task result so that Tekton Chains creates SLSA provenance for the attestation:

```yaml
results:
  - name: TEST_OUTPUT_ARTIFACT_OUTPUTS
    type: object
    properties:
      uri: {}
      digest: {}

steps:
  - name: create-attestation
    ref:
      resolver: git
      params:
        - name: url
          value: https://github.com/<org>/stepaction-attest-test-result
        - name: revision
          value: main
        - name: pathInRepo
          value: stepactions/attest-test-result/0.1/attest-test-result.yaml
    params:
      - name: image-url
        value: $(params.IMAGE_URL)
      - name: image-digest
        value: $(params.IMAGE_DIGEST)
      - name: test-name
        value: $(params.TEST_NAME)
      - name: test-output
        value: $(steps.run-test.results.TEST_OUTPUT)
      - name: cosign-key-path
        value: $(workspaces.cosign-keys.path)/cosign.key
```
