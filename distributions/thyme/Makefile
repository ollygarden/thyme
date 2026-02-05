.PHONY: build generate install-ocb run clean validate

OCB_VERSION ?= 0.144.0
BINARY_NAME = thyme
LOCAL_BIN = $(shell pwd)/bin
BUILDER = $(LOCAL_BIN)/builder

# Install ocb if not present (download binary to avoid module issues)
install-ocb:
	@mkdir -p $(LOCAL_BIN)
	@if [ ! -f $(BUILDER) ]; then \
		OS=$$(uname | tr A-Z a-z); \
		MACHINE=$$(uname -m); \
		[ "$${MACHINE}" != x86 ] || MACHINE=386; \
		[ "$${MACHINE}" != x86_64 ] || MACHINE=amd64; \
		echo "Downloading ocb v$(OCB_VERSION) for $${OS}/$${MACHINE}..."; \
		curl -sfLo $(BUILDER) "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/cmd%2Fbuilder%2Fv$(OCB_VERSION)/ocb_$(OCB_VERSION)_$${OS}_$${MACHINE}"; \
		chmod +x $(BUILDER); \
	fi

# Build the collector
build: install-ocb
	$(BUILDER) --config=manifest.yaml

# Generate sources without compiling (for goreleaser)
generate: install-ocb
	$(BUILDER) --skip-compilation --config=manifest.yaml

# Run the collector with sample config
run: build
	./build/$(BINARY_NAME) --config=config.yaml

# Clean build artifacts
clean:
	rm -rf ./build $(LOCAL_BIN)

# Validate configuration
validate: build
	./build/$(BINARY_NAME) validate --config=config.yaml
