#!/bin/bash
# Toggle Vault Cleanup Script
# Removes Toggle Vault resources from Azure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

# Default values
FORCE=false
DELETE_RG=false

# Usage information
usage() {
    cat << EOF
Toggle Vault Cleanup Script

Usage: $0 --config <path-to-manifest.yaml> [OPTIONS]

Required:
  --config PATH           Path to regional manifest.yaml configuration file

Options:
  --force                 Skip confirmation prompts
  --delete-resource-group Delete the entire resource group (irreversible!)
  --help                  Show this help message

Examples:
  # Interactive cleanup
  $0 --config ../kubernetes/overlays/eastus/manifest.yaml

  # Force cleanup without prompts
  $0 --config ../kubernetes/overlays/eastus/manifest.yaml --force

  # Delete entire resource group
  $0 --config ../kubernetes/overlays/eastus/manifest.yaml --delete-resource-group --force

EOF
    exit 1
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --delete-resource-group)
                DELETE_RG=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "Configuration file is required"
        usage
    fi
}

# Confirm action
confirm() {
    local message="$1"
    
    if [[ "$FORCE" == true ]]; then
        return 0
    fi
    
    echo -e "${YELLOW}$message${NC}"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
}

# Delete Kubernetes resources
delete_kubernetes_resources() {
    log_info "Deleting Kubernetes resources..."
    
    # Try to get credentials (may fail if cluster is already deleted)
    if az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "${AKS_NAME}-${REGION}" \
        --overwrite-existing 2>/dev/null; then
        
        # Delete namespace (this deletes all resources in it)
        kubectl delete namespace toggle-vault --ignore-not-found=true --timeout=60s || true
        
        log_success "Kubernetes resources deleted"
    else
        log_warning "Could not connect to AKS cluster (may already be deleted)"
    fi
}

# Delete AKS cluster
delete_aks_cluster() {
    local cluster_name="${AKS_NAME}-${REGION}"
    
    log_info "Deleting AKS cluster: $cluster_name"
    
    if az aks show --resource-group "$RESOURCE_GROUP" --name "$cluster_name" &>/dev/null; then
        az aks delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$cluster_name" \
            --yes \
            --no-wait
        
        log_success "AKS cluster deletion initiated"
    else
        log_warning "AKS cluster not found"
    fi
}

# Delete Managed Identity
delete_managed_identity() {
    local identity_name="id-toggle-vault-${REGION}"
    
    log_info "Deleting Managed Identity: $identity_name"
    
    if az identity show --resource-group "$RESOURCE_GROUP" --name "$identity_name" &>/dev/null; then
        az identity delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$identity_name"
        
        log_success "Managed Identity deleted"
    else
        log_warning "Managed Identity not found"
    fi
}

# Delete resource group
delete_resource_group() {
    log_info "Deleting resource group: $RESOURCE_GROUP"
    
    confirm "This will delete the ENTIRE resource group and all resources in it!"
    
    az group delete \
        --name "$RESOURCE_GROUP" \
        --yes \
        --no-wait
    
    log_success "Resource group deletion initiated"
}

# Main execution
main() {
    echo ""
    log_info "Toggle Vault Cleanup"
    log_info "===================="
    echo ""
    
    # Parse command line arguments
    parse_args "$@"
    
    # Check prerequisites
    check_command "az"
    check_command "kubectl"
    check_command "yq"
    
    # Check Azure CLI login status
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure CLI. Please run 'az login' first."
        exit 1
    fi
    
    # Load configuration
    parse_config "$CONFIG_FILE"
    
    echo ""
    echo "This will delete the following resources:"
    echo "  Region:           $REGION"
    echo "  Resource Group:   $RESOURCE_GROUP"
    echo "  AKS Cluster:      ${AKS_NAME}-${REGION}"
    echo "  Managed Identity: id-toggle-vault-${REGION}"
    echo ""
    
    if [[ "$DELETE_RG" == true ]]; then
        echo -e "${RED}WARNING: The entire resource group will be deleted!${NC}"
        echo ""
    fi
    
    confirm "This action cannot be undone."
    
    if [[ "$DELETE_RG" == true ]]; then
        # Deleting the resource group deletes everything
        delete_resource_group
    else
        # Delete individual resources
        delete_kubernetes_resources
        delete_aks_cluster
        delete_managed_identity
    fi
    
    echo ""
    log_success "Cleanup initiated successfully"
    echo ""
    echo "Note: Some resources may take a few minutes to fully delete."
    echo "To check status: az group show --name $RESOURCE_GROUP"
    echo ""
}

main "$@"
