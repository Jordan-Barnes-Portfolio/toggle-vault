#!/bin/bash
# Toggle Vault Deployment Script
# Deploys Toggle Vault to Azure Kubernetes Service with Managed Identity

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$DEPLOY_DIR")"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

# Default values
BUILD_IMAGE=false
SKIP_INFRA=false
SKIP_K8S=false

# Usage information
usage() {
    cat << EOF
Toggle Vault Deployment Script

Usage: $0 --config <path-to-manifest.yaml> [OPTIONS]

Required:
  --config PATH           Path to regional manifest.yaml configuration file

Options:
  --build-image           Build and push Docker image before deploying
  --skip-infra            Skip infrastructure deployment (ARM template)
  --skip-k8s              Skip Kubernetes deployment
  --help                  Show this help message

Examples:
  # Full deployment
  $0 --config ../kubernetes/overlays/eastus/manifest.yaml

  # Deploy only Kubernetes resources (infra already exists)
  $0 --config ../kubernetes/overlays/eastus/manifest.yaml --skip-infra

  # Build image and deploy everything
  $0 --config ../kubernetes/overlays/eastus/manifest.yaml --build-image

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
            --build-image)
                BUILD_IMAGE=true
                shift
                ;;
            --skip-infra)
                SKIP_INFRA=true
                shift
                ;;
            --skip-k8s)
                SKIP_K8S=true
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

# Build and push Docker image
build_image() {
    log_info "Building Docker image..."
    
    cd "$PROJECT_ROOT"
    
    local full_image="$CONTAINER_REGISTRY/$CONTAINER_IMAGE:$CONTAINER_TAG"
    
    # Build the image
    docker build -t "$full_image" .
    
    # Login to ACR
    log_info "Logging in to Azure Container Registry..."
    az acr login --name "$(echo $CONTAINER_REGISTRY | cut -d'.' -f1)"
    
    # Push the image
    log_info "Pushing image to registry..."
    docker push "$full_image"
    
    log_success "Image pushed: $full_image"
}

# Deploy Azure infrastructure using ARM template
deploy_infrastructure() {
    log_info "Deploying Azure infrastructure..."
    
    # Create resource group if it doesn't exist
    log_info "Creating resource group: $RESOURCE_GROUP"
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$REGION" \
        --tags application=toggle-vault environment="$ENVIRONMENT"
    
    # Verify storage account exists
    verify_storage_account "$STORAGE_ACCOUNT_NAME" "$STORAGE_ACCOUNT_RG"
    
    # Deploy ARM template
    log_info "Deploying ARM template..."
    DEPLOYMENT_OUTPUT=$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$DEPLOY_DIR/arm/main.json" \
        --parameters \
            location="$REGION" \
            environmentName="$ENVIRONMENT" \
            clusterName="$AKS_NAME" \
            nodeCount="$AKS_NODE_COUNT" \
            nodeVmSize="$AKS_NODE_SIZE" \
            kubernetesVersion="$AKS_K8S_VERSION" \
            storageAccountName="$STORAGE_ACCOUNT_NAME" \
            storageAccountResourceGroup="$STORAGE_ACCOUNT_RG" \
        --query "properties.outputs" \
        --output json)
    
    # Extract outputs
    export AKS_FULL_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.aksName.value')
    export MANAGED_IDENTITY_CLIENT_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.managedIdentityClientId.value')
    export MANAGED_IDENTITY_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.managedIdentityName.value')
    export OIDC_ISSUER_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.oidcIssuerUrl.value')
    
    log_success "Infrastructure deployed successfully"
    log_info "AKS Cluster: $AKS_FULL_NAME"
    log_info "Managed Identity Client ID: $MANAGED_IDENTITY_CLIENT_ID"
}

# Get AKS credentials
get_aks_credentials() {
    log_info "Getting AKS credentials..."
    
    az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_FULL_NAME" \
        --overwrite-existing
    
    log_success "AKS credentials configured"
}

# Deploy Kubernetes resources
deploy_kubernetes() {
    log_info "Deploying Kubernetes resources..."
    
    local K8S_BASE="$DEPLOY_DIR/kubernetes/base"
    local TEMP_DIR=$(mktemp -d)
    
    # Set additional environment variables for substitution
    export SYNC_INTERVAL="$APP_SYNC_INTERVAL"
    export IMAGE_TAG="$CONTAINER_TAG"
    
    # Apply namespace first
    kubectl apply -f "$K8S_BASE/namespace.yaml"
    
    # Process and apply service account with managed identity
    log_info "Creating service account with workload identity..."
    envsubst < "$K8S_BASE/serviceaccount.yaml" > "$TEMP_DIR/serviceaccount.yaml"
    kubectl apply -f "$TEMP_DIR/serviceaccount.yaml"
    
    # Process and apply configmap
    log_info "Creating ConfigMap..."
    envsubst < "$K8S_BASE/configmap.yaml" > "$TEMP_DIR/configmap.yaml"
    kubectl apply -f "$TEMP_DIR/configmap.yaml"
    
    # Apply PVC
    log_info "Creating PersistentVolumeClaim..."
    kubectl apply -f "$K8S_BASE/pvc.yaml"
    
    # Process and apply deployment
    log_info "Creating Deployment..."
    envsubst < "$K8S_BASE/deployment.yaml" > "$TEMP_DIR/deployment.yaml"
    kubectl apply -f "$TEMP_DIR/deployment.yaml"
    
    # Apply service
    log_info "Creating Service..."
    kubectl apply -f "$K8S_BASE/service.yaml"
    
    # Cleanup temp directory
    rm -rf "$TEMP_DIR"
    
    # Wait for deployment to be ready
    wait_for_deployment "toggle-vault" "toggle-vault"
    
    log_success "Kubernetes resources deployed"
}

# Print deployment summary
print_summary() {
    log_info "Fetching service details..."
    
    EXTERNAL_IP=$(get_external_ip "toggle-vault" "toggle-vault-service" 30) || EXTERNAL_IP="<pending>"
    
    echo ""
    echo "=============================================="
    echo "      Toggle Vault Deployment Complete        "
    echo "=============================================="
    echo ""
    echo "Region:              $REGION"
    echo "Resource Group:      $RESOURCE_GROUP"
    echo "AKS Cluster:         $AKS_FULL_NAME"
    echo "Managed Identity:    $MANAGED_IDENTITY_NAME"
    echo ""
    echo "Storage Account:     $STORAGE_ACCOUNT_NAME"
    echo "Container:           $STORAGE_CONTAINER"
    echo ""
    echo "----------------------------------------------"
    echo "Application URL:     http://$EXTERNAL_IP:8080"
    echo "Health Check:        http://$EXTERNAL_IP:8080/api/health"
    echo "----------------------------------------------"
    echo ""
    echo "To check the status:"
    echo "  kubectl get pods -n toggle-vault"
    echo "  kubectl logs -n toggle-vault -l app.kubernetes.io/name=toggle-vault"
    echo ""
}

# Main execution
main() {
    echo ""
    log_info "Toggle Vault Deployment"
    log_info "========================"
    echo ""
    
    # Parse command line arguments
    parse_args "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Load configuration
    parse_config "$CONFIG_FILE"
    
    # Build and push image if requested
    if [[ "$BUILD_IMAGE" == true ]]; then
        build_image
    fi
    
    # Deploy infrastructure
    if [[ "$SKIP_INFRA" == false ]]; then
        deploy_infrastructure
    else
        log_info "Skipping infrastructure deployment"
        # Need to get the managed identity client ID from existing deployment
        export AKS_FULL_NAME="${AKS_NAME}-${REGION}"
        export MANAGED_IDENTITY_CLIENT_ID=$(az identity show \
            --resource-group "$RESOURCE_GROUP" \
            --name "id-toggle-vault-$REGION" \
            --query clientId -o tsv 2>/dev/null || echo "")
        
        if [[ -z "$MANAGED_IDENTITY_CLIENT_ID" ]]; then
            log_error "Could not retrieve Managed Identity Client ID. Is the infrastructure deployed?"
            exit 1
        fi
    fi
    
    # Get AKS credentials
    get_aks_credentials
    
    # Deploy Kubernetes resources
    if [[ "$SKIP_K8S" == false ]]; then
        deploy_kubernetes
    else
        log_info "Skipping Kubernetes deployment"
    fi
    
    # Print summary
    print_summary
}

main "$@"
