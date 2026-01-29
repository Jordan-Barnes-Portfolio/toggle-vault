#!/bin/bash
# Initial setup script - makes all scripts executable and validates environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Setting up Toggle Vault deployment scripts..."

# Make scripts executable
chmod +x "$SCRIPT_DIR/deploy.sh"
chmod +x "$SCRIPT_DIR/destroy.sh"
chmod +x "$SCRIPT_DIR/utils.sh"

echo "Scripts are now executable."
echo ""

# Check for required tools
echo "Checking required tools..."

check_tool() {
    if command -v "$1" &> /dev/null; then
        echo "  ✓ $1 found"
        return 0
    else
        echo "  ✗ $1 NOT FOUND"
        return 1
    fi
}

MISSING=0

check_tool "az" || MISSING=$((MISSING + 1))
check_tool "kubectl" || MISSING=$((MISSING + 1))
check_tool "yq" || MISSING=$((MISSING + 1))
check_tool "jq" || MISSING=$((MISSING + 1))
check_tool "docker" || echo "  ! docker not found (optional - only needed for --build-image)"
check_tool "envsubst" || MISSING=$((MISSING + 1))

echo ""

if [[ $MISSING -gt 0 ]]; then
    echo "Missing $MISSING required tool(s). Please install them before proceeding."
    echo ""
    echo "Installation hints:"
    echo "  az:       https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    echo "  kubectl:  https://kubernetes.io/docs/tasks/tools/"
    echo "  yq:       https://github.com/mikefarah/yq#install"
    echo "  jq:       https://stedolan.github.io/jq/download/"
    echo "  envsubst: Usually part of 'gettext' package"
    exit 1
fi

echo "All required tools are installed."
echo ""
echo "Next steps:"
echo "  1. Copy a regional manifest template:"
echo "     cp ../kubernetes/overlays/template/manifest.yaml ../kubernetes/overlays/<your-region>/manifest.yaml"
echo ""
echo "  2. Edit the manifest with your settings"
echo ""
echo "  3. Login to Azure:"
echo "     az login"
echo ""
echo "  4. Run the deployment:"
echo "     ./deploy.sh --config ../kubernetes/overlays/<your-region>/manifest.yaml"
echo ""
