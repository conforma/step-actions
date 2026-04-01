IMAGE_REPO ?= quay.io/conforma/attest-test-result
IMAGE_TAG  ?= 0.1
IMAGE      := $(IMAGE_REPO):$(IMAGE_TAG)

COSIGN_VERSION ?= v2.5.3
ORAS_VERSION   ?= v1.2.2

.PHONY: build push all

all: build push

build:
	docker build \
		--build-arg COSIGN_VERSION=$(COSIGN_VERSION) \
		--build-arg ORAS_VERSION=$(ORAS_VERSION) \
		-t $(IMAGE) .

push:
	docker push $(IMAGE)
