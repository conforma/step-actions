# create-test-result-attestation

Creates and pushes an unsigned in-toto test-result attestation to a container registry using `oras attach`. The attestation is attached as an OCI referrer, discoverable via the referrers API.

Trust is not established by signing the attestation itself. Instead, the step outputs an `*_ARTIFACT_OUTPUTS` result that causes Tekton Chains to generate SLSA provenance for the attestation. Verifiers check this Chains-generated provenance to confirm the attestation was created by a trusted pipeline.

## Parameters

| name | description | default value | required |
|------|-------------|---------------|----------|
| image-url | Image URL without digest (e.g. quay.io/org/image) | | true |
| image-digest | Image digest (sha256:...) | | true |
| test-name | Name of the test (e.g. integration-test, clair-scan) | | true |
| test-output | JSON test results to include in the attestation predicate | | true |
| predicate-type | In-toto predicate type URI | `https://in-toto.io/attestation/test-result/v0.1` | false |

## Results

| name | description |
|------|-------------|
| TEST_OUTPUT_ARTIFACT_OUTPUTS | JSON object with `uri` and `digest` fields referencing the pushed attestation. Tekton Chains uses this for SLSA provenance. |

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
```

## Chain of Trust

```
Image ──► Test-result attestation (unsigned, attached via oras)
              │
              ▼
          ARTIFACT_OUTPUTS result
              │
              ▼
          Tekton Chains generates SLSA provenance
          (subject = attestation digest, signed by Chains)
              │
              ▼
          Verifier checks provenance to confirm
          attestation came from a trusted pipeline
```
