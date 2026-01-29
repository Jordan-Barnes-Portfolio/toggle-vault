# Toggle Vault Makefile
# Build and package for airgap deployment

IMAGE_NAME := toggle-vault
IMAGE_TAG := latest
IMAGE_TAR := toggle-vault-image.tar
AIRGAP_PACKAGE := toggle-vault-airgap-package.tar.gz

.PHONY: all build package clean help

# Default target
all: package

# Build Docker image for linux/amd64 (required for Azure/AKS)
build:
	@echo "Building Docker image $(IMAGE_NAME):$(IMAGE_TAG) for linux/amd64..."
	docker build --platform linux/amd64 -t $(IMAGE_NAME):$(IMAGE_TAG) .
	@echo ""
	@echo "Exporting image to $(IMAGE_TAR)..."
	docker save -o $(IMAGE_TAR) $(IMAGE_NAME):$(IMAGE_TAG)
	@echo "Image exported: $(IMAGE_TAR) ($$(du -h $(IMAGE_TAR) | cut -f1))"

# Package everything needed for airgap deployment
package: build
	@echo ""
	@echo "Creating airgap deployment package..."
	tar -czvf $(AIRGAP_PACKAGE) \
		$(IMAGE_TAR) \
		airgap-deploy.sh \
		AIRGAP_DEPLOYMENT.md
	@echo ""
	@echo "=============================================="
	@echo "Airgap package created: $(AIRGAP_PACKAGE)"
	@echo "Size: $$(du -h $(AIRGAP_PACKAGE) | cut -f1)"
	@echo "=============================================="
	@echo ""
	@echo "Contents:"
	@tar -tzf $(AIRGAP_PACKAGE)
	@echo ""
	@echo "Transfer this single file to your airgapped environment."

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -f $(IMAGE_TAR) $(AIRGAP_PACKAGE)
	@echo "Done."

# Help
help:
	@echo "Toggle Vault Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make build    - Build Docker image and export to tar"
	@echo "  make package  - Build image and create airgap deployment package"
	@echo "  make clean    - Remove build artifacts"
	@echo "  make help     - Show this help"
	@echo ""
	@echo "Output:"
	@echo "  $(AIRGAP_PACKAGE) - Complete package for airgap deployment"
