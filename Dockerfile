FROM registry.access.redhat.com/ubi9/ubi-minimal:latest@sha256:c7d44146f826037f6873d99da479299b889473492d3c1ab8af86f08af04ec8a0

ARG COSIGN_VERSION=v2.5.3
ARG ORAS_VERSION=v1.2.2
ARG TARGETARCH

RUN microdnf -y --nodocs --setopt=keepcache=0 install jq tar gzip && \
    microdnf clean all

RUN curl -sLo /usr/local/bin/cosign \
      "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" && \
    chmod +x /usr/local/bin/cosign

RUN curl -sLo /tmp/oras.tar.gz \
      "https://github.com/oras-project/oras/releases/download/${ORAS_VERSION}/oras_${ORAS_VERSION#v}_linux_${TARGETARCH}.tar.gz" && \
    tar -xzf /tmp/oras.tar.gz -C /usr/local/bin oras && \
    rm -f /tmp/oras.tar.gz
