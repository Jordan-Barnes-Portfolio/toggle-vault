#!/bin/bash
# Utility functions for Toggle Vault deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if a command exists
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command '$1' not found. Please install it first."
        exit 1
    fi
}

# Check required commands
check_prerequisites() {
    log_info "Checking prerequisites..."
    check_command "az"
    check_command "kubectl"
    check_command "yq"
    
    # Check Azure CLI login status
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure CLI. Please run 'az login' first."
        exit 1
    fi
    
    log_success "All prerequisites met"
}

# Parse YAML configuration file
parse_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
    
    # Export all configuration values as environment variables
    export REGION=$(yq e '.region' "$config_file")
    export ENVIRONMENT=$(yq e '.environment' "$config_file")
    export RESOURCE_GROUP=$(yq e '.azure.resourceGroup' "$config_file")
    export STORAGE_ACCOUNT_NAME=$(yq e '.azure.storageAccount.name' "$config_file")
    export STORAGE_ACCOUNT_RG=$(yq e '.azure.storageAccount.resourceGroup // ""' "$config_file")
    export STORAGE_PREFIX=$(yq e '.azure.storageAccount.prefix // ""' "$config_file")
    export CONTAINER_REGISTRY=$(yq e '.container.registry' "$config_file")
    export CONTAINER_IMAGE=$(yq e '.container.image' "$config_file")
    export CONTAINER_TAG=$(yq e '.container.tag' "$config_file")
    export AKS_NAME=$(yq e '.aks.name' "$config_file")
    export AKS_NODE_COUNT=$(yq e '.aks.nodeCount' "$config_file")
    export AKS_NODE_SIZE=$(yq e '.aks.nodeSize' "$config_file")
    export AKS_K8S_VERSION=$(yq e '.aks.kubernetesVersion' "$config_file")
    export APP_SYNC_INTERVAL=$(yq e '.app.syncInterval' "$config_file")
    export APP_REPLICAS=$(yq e '.app.replicas' "$config_file")
    
    # Handle container scope options
    local scan_all=$(yq e '.azure.storageAccount.scanAllContainers // false' "$config_file")
    local containers=$(yq e '.azure.storageAccount.containers // []' "$config_file")
    local container=$(yq e '.azure.storageAccount.container // ""' "$config_file")
    
    if [[ "$scan_all" == "true" ]]; then
        export CONTAINER_CONFIG="scan_all_containers: true"
        export STORAGE_CONTAINER_NAME="(all containers)"
    elif [[ "$containers" != "[]" && "$containers" != "null" ]]; then
        # Multiple containers - format as YAML list
        export CONTAINER_CONFIG=$(yq e '.azure.storageAccount.containers | "containers:\n" + (. | map("  - " + .) | join("\n"))' "$config_file")
        export STORAGE_CONTAINER_NAME="(multiple)"
    elif [[ -n "$container" && "$container" != "null" ]]; then
        export CONTAINER_CONFIG="container: \"$container\""
        export STORAGE_CONTAINER_NAME="$container"
    else
        log_error "No container scope configured. Set container, containers, or scanAllContainers."
        exit 1
    fi
    
    # Use resource group for storage if not specified
    if [[ -z "$STORAGE_ACCOUNT_RG" || "$STORAGE_ACCOUNT_RG" == "null" ]]; then
        export STORAGE_ACCOUNT_RG="$RESOURCE_GROUP"
    fi
    
    log_info "Configuration loaded for region: $REGION"
}

# Substitute environment variables in a file
substitute_vars() {
    local input_file="$1"
    local output_file="$2"
    
    envsubst < "$input_file" > "$output_file"
}

# Wait for a Kubernetes deployment to be ready
wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-300}"
    
    log_info "Waiting for deployment $deployment to be ready..."
    kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="${timeout}s"
}

# Get the external IP of a LoadBalancer service
get_external_ip() {
    local namespace="$1"
    local service="$2"
    local max_attempts="${3:-30}"
    
    log_info "Waiting for external IP..."
    
    for ((i=1; i<=max_attempts; i++)); do
        EXTERNAL_IP=$(kubectl get svc "$service" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$EXTERNAL_IP" && "$EXTERNAL_IP" != "null" ]]; then
            echo "$EXTERNAL_IP"
            return 0
        fi
        
        sleep 10
    done
    
    log_error "Timed out waiting for external IP"
    return 1
}

# Verify storage account exists and is accessible
verify_storage_account() {
    local storage_account="$1"
    local resource_group="$2"
    
    log_info "Verifying storage account: $storage_account"
    
    if ! az storage account show --name "$storage_account" --resource-group "$resource_group" &> /dev/null; then
        log_error "Storage account '$storage_account' not found in resource group '$resource_group'"
        exit 1
    fi
    
    log_success "Storage account verified"
}
