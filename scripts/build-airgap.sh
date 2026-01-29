#!/bin/bash
# build-airgap.sh - Build Toggle Vault Docker image for airgapped deployment
#
# This script builds the Docker image and exports it as a tar file that can be
# transferred to an airgapped environment with only Azure access.
#
# Usage:
#   ./scripts/build-airgap.sh [OPTIONS]
#
# Options:
#   --tag TAG           Image tag (default: toggle-vault:latest)
#   --output FILE       Output tar file (default: toggle-vault-image.tar)
#   --registry URL      ACR registry URL (e.g., myregistry.azurecr.io)
#   --push              Push to registry after building (requires --registry)
#   --no-export         Skip exporting to tar file
#   --help              Show this help message

set -e

# Default values
IMAGE_TAG="toggle-vault:latest"
OUTPUT_FILE="toggle-vault-image.tar"
REGISTRY=""
PUSH=false
EXPORT=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --no-export)
            EXPORT=false
            shift
            ;;
        --help)
            head -20 "$0" | tail -18
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

echo "=========================================="
echo "Toggle Vault - Airgap Build"
echo "=========================================="
echo ""

# Build the image for amd64 (required for Azure/Linux servers)
echo "Building Docker image: $IMAGE_TAG (linux/amd64)"
echo ""
docker build --platform linux/amd64 -t "$IMAGE_TAG" .

if [ $? -ne 0 ]; then
    echo "ERROR: Docker build failed"
    exit 1
fi

echo ""
echo "Build successful!"

# Tag for registry if specified
if [ -n "$REGISTRY" ]; then
    FULL_TAG="$REGISTRY/$IMAGE_TAG"
    echo "Tagging image as: $FULL_TAG"
    docker tag "$IMAGE_TAG" "$FULL_TAG"
    
    if [ "$PUSH" = true ]; then
        echo "Pushing to registry..."
        docker push "$FULL_TAG"
        echo "Push complete!"
    fi
fi

# Export to tar file
if [ "$EXPORT" = true ]; then
    echo ""
    echo "Exporting image to: $OUTPUT_FILE"
    
    if [ -n "$REGISTRY" ]; then
        docker save -o "$OUTPUT_FILE" "$IMAGE_TAG" "$FULL_TAG"
    else
        docker save -o "$OUTPUT_FILE" "$IMAGE_TAG"
    fi
    
    # Get file size
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo "Export complete! File size: $SIZE"
fi

echo ""
echo "=========================================="
echo "Build Summary"
echo "=========================================="
echo "Image:    $IMAGE_TAG"
[ -n "$REGISTRY" ] && echo "Registry: $FULL_TAG"
[ "$EXPORT" = true ] && echo "Tar file: $OUTPUT_FILE ($SIZE)"
echo ""
echo "Next steps for airgapped deployment:"
echo "  1. Transfer $OUTPUT_FILE to the airgapped environment"
echo "  2. Run: ./scripts/load-airgap.sh --input $OUTPUT_FILE"
echo "  3. Push to your Azure Container Registry"
echo ""
