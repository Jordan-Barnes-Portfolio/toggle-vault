# Toggle Vault Makefile
# Build and package for airgap deployment

IMAGE_NAME := toggle-vault
INIT_IMAGE_NAME := toggle-vault-init
IMAGE_TAG := latest
DIST_DIR := dist
IMAGE_TAR := $(DIST_DIR)/toggle-vault-image.tar
INIT_IMAGE_TAR := $(DIST_DIR)/toggle-vault-init-image.tar
AIRGAP_PACKAGE := $(DIST_DIR)/toggle-vault-airgap-package.tar.gz

.PHONY: all build build-init package clean help

# Default target
all: package

# Build main Docker image for linux/amd64 (required for Azure/AKS)
build:
	@mkdir -p $(DIST_DIR)
	@echo "Building Docker image $(IMAGE_NAME):$(IMAGE_TAG) for linux/amd64..."
	docker build --platform linux/amd64 -t $(IMAGE_NAME):$(IMAGE_TAG) .
	@echo ""
	@echo "Exporting image to $(IMAGE_TAR)..."
	docker save -o $(IMAGE_TAR) $(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Image exported: $(IMAGE_TAR) ($$(du -h $(IMAGE_TAR) | cut -f1))"

# Build init container image for linux/amd64
build-init:
	@mkdir -p $(DIST_DIR)
	@echo "Building init container image $(INIT_IMAGE_NAME):$(IMAGE_TAG) for linux/amd64..."
	docker build --platform linux/amd64 -t $(INIT_IMAGE_NAME):$(IMAGE_TAG) -f Dockerfile.init .
	@echo ""
	@echo "Exporting init image to $(INIT_IMAGE_TAR)..."
	docker save -o $(INIT_IMAGE_TAR) $(INIT_IMAGE_NAME):$(IMAGE_TAG)
	@echo "Init image exported: $(INIT_IMAGE_TAR) ($$(du -h $(INIT_IMAGE_TAR) | cut -f1))"

# Package everything needed for airgap deployment
package: build build-init
	@echo ""
	@echo "Creating airgap deployment package..."
	@cp airgap-deploy.sh AIRGAP_DEPLOYMENT.md README.md $(DIST_DIR)/
	@cd $(DIST_DIR) && tar -czvf toggle-vault-airgap-package.tar.gz \
		toggle-vault-image.tar \
		toggle-vault-init-image.tar \
		airgap-deploy.sh \
		AIRGAP_DEPLOYMENT.md \
		README.md
	@echo ""
	@echo "=============================================="
	@echo "Airgap package created: $(AIRGAP_PACKAGE)"
	@echo "Size: $$(du -h $(AIRGAP_PACKAGE) | cut -f1)"
	@echo "=============================================="
	@echo ""
	@echo "Contents:"
	@tar -tzf $(AIRGAP_PACKAGE)
	@echo ""
	@echo "All artifacts are in the '$(DIST_DIR)' folder."
	@echo "Transfer $(AIRGAP_PACKAGE) to your airgapped environment."

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(DIST_DIR)
	@echo "Done."

# Help
help:
	@echo "Toggle Vault Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make build      - Build main Docker image and export to tar"
	@echo "  make build-init - Build init container image and export to tar"
	@echo "  make package    - Build all images and create airgap deployment package"
	@echo "  make clean      - Remove build artifacts (dist folder)"
	@echo "  make help       - Show this help"
	@echo ""
	@echo "Output:"
	@echo "  $(DIST_DIR)/                    - All build artifacts"
	@echo "  $(AIRGAP_PACKAGE) - Complete package for airgap deployment"
