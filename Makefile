.PHONY: build generate run validate clean docker-build docker-push k3d-load

# Build the distribution
build:
	$(MAKE) -C distributions/thyme build

# Generate sources without compiling (for goreleaser)
generate:
	$(MAKE) -C distributions/thyme generate

# Run the distribution
run:
	$(MAKE) -C distributions/thyme run

# Validate the configuration
validate:
	$(MAKE) -C distributions/thyme validate

# Clean build artifacts
clean:
	$(MAKE) -C distributions/thyme clean

# Build Docker image
docker-build:
	docker build -t ghcr.io/ollygarden/thyme:latest .

# Build and push Docker image to GHCR
docker-push: docker-build
	docker push ghcr.io/ollygarden/thyme:latest

# Build and load into k3d cluster
k3d-load: docker-build
	@CLUSTER_NAME=$${K3D_CLUSTER:-k3s-default}; \
	echo "Loading image into k3d cluster: $$CLUSTER_NAME"; \
	k3d image import ghcr.io/ollygarden/thyme:latest -c $$CLUSTER_NAME
