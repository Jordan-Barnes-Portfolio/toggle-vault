#!/bin/bash
# load-airgap.sh - Load Toggle Vault Docker image in airgapped environment
#
# This script loads a previously exported Docker image and pushes it to
# Azure Container Registry.
#
# Usage:
#   ./scripts/load-airgap.sh [OPTIONS]
#
# Options:
#   --input FILE        Input tar file (default: toggle-vault-image.tar)
#   --registry URL      ACR registry URL (required for push)
#   --tag TAG           Image tag (default: toggle-vault:latest)
#   --push              Push to ACR after loading
#   --help              Show this help message

set -e

# Default values
INPUT_FILE="toggle-vault-image.tar"
REGISTRY=""
IMAGE_TAG="toggle-vault:latest"
PUSH=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --input)
            INPUT_FILE="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --help)
            head -18 "$0" | tail -16
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=========================================="
echo "Toggle Vault - Airgap Load"
echo "=========================================="
echo ""

# Check input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: $INPUT_FILE"
    exit 1
fi

# Load the image
echo "Loading Docker image from: $INPUT_FILE"
docker load -i "$INPUT_FILE"

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to load Docker image"
    exit 1
fi

echo ""
echo "Image loaded successfully!"

# Push to registry if requested
if [ "$PUSH" = true ]; then
    if [ -z "$REGISTRY" ]; then
        echo "ERROR: --registry is required when using --push"
        exit 1
    fi
    
    FULL_TAG="$REGISTRY/$IMAGE_TAG"
    
    echo ""
    echo "Tagging image as: $FULL_TAG"
    docker tag "$IMAGE_TAG" "$FULL_TAG"
    
    echo "Logging into Azure Container Registry..."
    az acr login --name "$(echo $REGISTRY | cut -d. -f1)"
    
    echo "Pushing to registry..."
    docker push "$FULL_TAG"
    
    echo ""
    echo "Push complete!"
    echo "Image available at: $FULL_TAG"
fi

echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
if [ "$PUSH" = true ]; then
    echo "Your image is now in ACR. Deploy to AKS with:"
    echo "  cd deploy/scripts"
    echo "  ./deploy.sh --config ../kubernetes/overlays/<region>/manifest.yaml"
else
    echo "To push to Azure Container Registry:"
    echo "  az acr login --name <your-acr-name>"
    echo "  docker tag $IMAGE_TAG <your-acr>.azurecr.io/$IMAGE_TAG"
    echo "  docker push <your-acr>.azurecr.io/$IMAGE_TAG"
fi
echo ""
