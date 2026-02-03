#!/bin/bash
#
# Toggle Vault - Airgap Deployment Script
#
# This script deploys Toggle Vault to Azure Kubernetes Service.
# It creates all required Azure resources including ACR and AKS.
# It is completely self-contained and requires no other files except the Docker image tar.
#
# Usage:
#   ./airgap-deploy.sh --region <region> --storage-account <sa> --storage-rg <rg>
#
# Run with --help for all options.
#

set -e

#==============================================================================
# Configuration Defaults
#==============================================================================

REGION=""
ACR_NAME=""
RESOURCE_GROUP=""
CLUSTER_NAME="aks-toggle-vault"
NODE_SIZE="Standard_B2s"
NODE_COUNT=1
K8S_VERSION="1.32"
IMAGE_TAG="latest"
IMAGE_TAR="toggle-vault-image.tar"
INIT_IMAGE_TAR="toggle-vault-init-image.tar"
SYNC_INTERVAL="60s"
DRY_RUN=false
SKIP_IMAGE_PUSH=false

# Storage accounts array - each entry is "name:subscription:resource_group:container:prefix"
# subscription, container, and prefix are optional
declare -a STORAGE_ACCOUNTS

#==============================================================================
# Colors and Logging
#==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

#==============================================================================
# Help
#==============================================================================

show_help() {
    cat << 'EOF'
Toggle Vault - Airgap Deployment Script

This script creates ALL required Azure resources and deploys Toggle Vault.
Place this script in the same directory as toggle-vault-image.tar and run it.

Supports multiple storage accounts across different subscriptions.

USAGE:
    ./airgap-deploy.sh [OPTIONS]

REQUIRED OPTIONS:
    --region              Azure region (e.g., eastus, westus2)
    --storage-account     Storage account(s) to monitor. Can be specified multiple times.
                          Format: name[:subscription_id][:resource_group][:container][:prefix]
                          - subscription_id: optional, defaults to current subscription
                          - resource_group: required
                          - container: optional, defaults to scan all containers
                          - prefix: optional, filter files by path prefix

OPTIONAL:
    --acr-name            ACR name (default: acrtogvault<region>, created if not exists)
    --resource-group      Resource group for Toggle Vault (default: rg-toggle-vault-<region>)
    --cluster-name        AKS cluster name (default: aks-toggle-vault)
    --node-size           VM size for nodes (default: Standard_B2s)
    --node-count          Number of nodes (default: 1)
    --image-tar           Path to main Docker image tar (default: toggle-vault-image.tar)
    --init-image-tar      Path to init container image tar (default: toggle-vault-init-image.tar)
    --image-tag           Docker image tag (default: latest)
    --sync-interval       Sync interval (default: 60s)
    --skip-image-push     Skip loading/pushing image (use if already in ACR)
    --dry-run             Show what would be created without creating it
    --help                Show this help message

STORAGE ACCOUNT FORMAT:
    The --storage-account option uses colon-separated values:
    
    Simple (same subscription):
      --storage-account "myaccount::myrg"
      
    With specific container:
      --storage-account "myaccount::myrg:toggles"
      
    Cross-subscription:
      --storage-account "myaccount:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx:myrg"
      
    Full format:
      --storage-account "name:subscription:rg:container:prefix"

EXAMPLES:
    # Single storage account (same subscription)
    ./airgap-deploy.sh \
        --region eastus \
        --storage-account "mystorage::rg-storage"

    # Multiple storage accounts
    ./airgap-deploy.sh \
        --region eastus \
        --storage-account "storage1::rg-storage1" \
        --storage-account "storage2::rg-storage2"

    # Cross-subscription storage account
    ./airgap-deploy.sh \
        --region eastus \
        --storage-account "storage1:11111111-1111-1111-1111-111111111111:rg-storage1" \
        --storage-account "storage2:22222222-2222-2222-2222-222222222222:rg-storage2"

    # With specific containers
    ./airgap-deploy.sh \
        --region eastus \
        --storage-account "mystorage::rg-storage:toggles"

    # Full example with all options
    ./airgap-deploy.sh \
        --region westus2 \
        --storage-account "storage1::rg-storage1:config:env/" \
        --storage-account "storage2:sub-id-2:rg-storage2" \
        --resource-group rg-togglevault-prod \
        --node-size Standard_B2ms

EOF
    exit 0
}

#==============================================================================
# Argument Parsing
#==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --region)           REGION="$2"; shift 2 ;;
            --acr-name)         ACR_NAME="$2"; shift 2 ;;
            --storage-account)  STORAGE_ACCOUNTS+=("$2"); shift 2 ;;
            --resource-group)   RESOURCE_GROUP="$2"; shift 2 ;;
            --cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
            --node-size)        NODE_SIZE="$2"; shift 2 ;;
            --node-count)       NODE_COUNT="$2"; shift 2 ;;
            --image-tar)        IMAGE_TAR="$2"; shift 2 ;;
            --init-image-tar)   INIT_IMAGE_TAR="$2"; shift 2 ;;
            --image-tag)        IMAGE_TAG="$2"; shift 2 ;;
            --sync-interval)    SYNC_INTERVAL="$2"; shift 2 ;;
            --skip-image-push)  SKIP_IMAGE_PUSH=true; shift ;;
            --dry-run)          DRY_RUN=true; shift ;;
            --help)             show_help ;;
            *)                  log_error "Unknown option: $1"; exit 1 ;;
        esac
    done

    # Set defaults that depend on other values
    [[ -z "$RESOURCE_GROUP" ]] && RESOURCE_GROUP="rg-toggle-vault-${REGION}"
    
    # Generate ACR name if not provided (must be alphanumeric, 5-50 chars)
    if [[ -z "$ACR_NAME" ]]; then
        # Remove hyphens and create a valid ACR name
        local clean_region=$(echo "$REGION" | tr -d '-')
        ACR_NAME="acrtogvault${clean_region}"
    fi

    # Validate required parameters
    local missing=()
    [[ -z "$REGION" ]] && missing+=("--region")
    [[ ${#STORAGE_ACCOUNTS[@]} -eq 0 ]] && missing+=("--storage-account")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required parameters: ${missing[*]}"
        echo ""
        echo "Run with --help for usage information."
        exit 1
    fi
    
    # Validate storage account format
    for sa in "${STORAGE_ACCOUNTS[@]}"; do
        local sa_name=$(echo "$sa" | cut -d: -f1)
        local sa_rg=$(echo "$sa" | cut -d: -f3)
        
        if [[ -z "$sa_name" ]]; then
            log_error "Invalid storage account format: '$sa' (missing name)"
            log_error "Expected format: name[:subscription][:resource_group][:container][:prefix]"
            exit 1
        fi
        
        if [[ -z "$sa_rg" ]]; then
            log_error "Invalid storage account format: '$sa' (missing resource group)"
            log_error "Expected format: name[:subscription]:resource_group[:container][:prefix]"
            exit 1
        fi
    done
}

# Parse a storage account string into components
# Format: name:subscription:resource_group:container:prefix
parse_storage_account() {
    local sa_string="$1"
    
    SA_NAME=$(echo "$sa_string" | cut -d: -f1)
    SA_SUBSCRIPTION=$(echo "$sa_string" | cut -d: -f2)
    SA_RG=$(echo "$sa_string" | cut -d: -f3)
    SA_CONTAINER=$(echo "$sa_string" | cut -d: -f4)
    SA_PREFIX=$(echo "$sa_string" | cut -d: -f5)
    
    # If subscription is empty, use current subscription
    if [[ -z "$SA_SUBSCRIPTION" ]]; then
        SA_SUBSCRIPTION=$(az account show --query id -o tsv)
    fi
}

#==============================================================================
# Prerequisite Checks
#==============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    
    command -v az >/dev/null 2>&1 || missing+=("az (Azure CLI)")
    command -v kubectl >/dev/null 2>&1 || missing+=("kubectl")
    
    # Docker is required unless skipping image push
    if [[ "$SKIP_IMAGE_PUSH" != true ]]; then
        command -v docker >/dev/null 2>&1 || missing+=("docker")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    # Check Azure login
    if ! az account show >/dev/null 2>&1; then
        log_error "Not logged into Azure. Run 'az login' first."
        exit 1
    fi
    
    # Check Docker is running (unless skipping image push)
    if [[ "$SKIP_IMAGE_PUSH" != true ]]; then
        if ! docker info >/dev/null 2>&1; then
            log_error "Docker is not running. Please start Docker first."
            exit 1
        fi
    fi
    
    # Check image tar exists (unless skipping image push)
    if [[ "$SKIP_IMAGE_PUSH" != true ]]; then
        if [[ ! -f "$IMAGE_TAR" ]]; then
            log_error "Docker image tar not found: $IMAGE_TAR"
            log_error "Place toggle-vault-image.tar in the current directory or specify --image-tar <path>"
            exit 1
        fi
        log_success "Image tar found: $IMAGE_TAR"
        
        # Check init image tar exists
        if [[ ! -f "$INIT_IMAGE_TAR" ]]; then
            log_error "Init container image tar not found: $INIT_IMAGE_TAR"
            log_error "Place toggle-vault-init-image.tar in the current directory or specify --init-image-tar <path>"
            exit 1
        fi
        log_success "Init image tar found: $INIT_IMAGE_TAR"
    fi
    
    log_success "All prerequisites met"
}

#==============================================================================
# Azure Resource Validation
#==============================================================================

validate_resources() {
    log_info "Validating existing Azure resources..."
    
    local current_sub=$(az account show --query id -o tsv)
    
    # Check each storage account exists
    for sa in "${STORAGE_ACCOUNTS[@]}"; do
        parse_storage_account "$sa"
        
        # Switch subscription if needed
        if [[ "$SA_SUBSCRIPTION" != "$current_sub" ]]; then
            log_info "Checking storage account '$SA_NAME' in subscription $SA_SUBSCRIPTION..."
            if ! az storage account show --name "$SA_NAME" --resource-group "$SA_RG" --subscription "$SA_SUBSCRIPTION" >/dev/null 2>&1; then
                log_error "Storage account '$SA_NAME' not found in resource group '$SA_RG' (subscription: $SA_SUBSCRIPTION)"
                log_error "The storage account must already exist with your toggle files."
                exit 1
            fi
        else
            if ! az storage account show --name "$SA_NAME" --resource-group "$SA_RG" >/dev/null 2>&1; then
                log_error "Storage account '$SA_NAME' not found in resource group '$SA_RG'"
                log_error "The storage account must already exist with your toggle files."
                exit 1
            fi
        fi
        log_success "Storage account '$SA_NAME' found"
        
        # Check container exists (only if specified)
        if [[ -n "$SA_CONTAINER" ]]; then
            if ! az storage container show --name "$SA_CONTAINER" --account-name "$SA_NAME" --auth-mode login --subscription "$SA_SUBSCRIPTION" >/dev/null 2>&1; then
                log_warn "Could not verify container '$SA_CONTAINER' in '$SA_NAME' exists (may be permissions issue, continuing...)"
            else
                log_success "Container '$SA_CONTAINER' found in '$SA_NAME'"
            fi
        else
            log_info "Storage account '$SA_NAME' - will scan all containers"
        fi
    done
}

#==============================================================================
# Create Azure Container Registry
#==============================================================================

create_acr() {
    log_info "Checking Azure Container Registry..."
    
    # Check if ACR already exists
    if az acr show --name "$ACR_NAME" >/dev/null 2>&1; then
        log_success "ACR '$ACR_NAME' already exists"
        return 0
    fi
    
    log_info "Creating Azure Container Registry: $ACR_NAME"
    
    az acr create \
        --name "$ACR_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$REGION" \
        --sku Basic \
        --admin-enabled false \
        --tags application=toggle-vault \
        --output none
    
    log_success "ACR '$ACR_NAME' created"
}

#==============================================================================
# Load and Push Docker Image
#==============================================================================

push_image() {
    if [[ "$SKIP_IMAGE_PUSH" == true ]]; then
        log_info "Skipping image push (--skip-image-push specified)"
        
        # Verify images exist in ACR
        if ! az acr repository show --name "$ACR_NAME" --repository toggle-vault >/dev/null 2>&1; then
            log_error "Image 'toggle-vault' not found in ACR '$ACR_NAME'"
            log_error "Remove --skip-image-push to load and push the image"
            exit 1
        fi
        log_success "Image 'toggle-vault' found in ACR"
        
        if ! az acr repository show --name "$ACR_NAME" --repository toggle-vault-init >/dev/null 2>&1; then
            log_error "Image 'toggle-vault-init' not found in ACR '$ACR_NAME'"
            log_error "Remove --skip-image-push to load and push the image"
            exit 1
        fi
        log_success "Image 'toggle-vault-init' found in ACR"
        return 0
    fi
    
    log_info "Logging into ACR: $ACR_NAME"
    az acr login --name "$ACR_NAME"
    
    # Load and push main image
    log_info "Loading main Docker image from: $IMAGE_TAR"
    docker load -i "$IMAGE_TAR"
    log_success "Main image loaded"
    
    local FULL_IMAGE="${ACR_NAME}.azurecr.io/toggle-vault:${IMAGE_TAG}"
    
    log_info "Tagging image as: $FULL_IMAGE"
    docker tag toggle-vault:latest "$FULL_IMAGE"
    
    log_info "Pushing main image to ACR..."
    docker push "$FULL_IMAGE"
    log_success "Main image pushed to ACR"
    
    # Load and push init image
    log_info "Loading init container image from: $INIT_IMAGE_TAR"
    docker load -i "$INIT_IMAGE_TAR"
    log_success "Init image loaded"
    
    local FULL_INIT_IMAGE="${ACR_NAME}.azurecr.io/toggle-vault-init:${IMAGE_TAG}"
    
    log_info "Tagging init image as: $FULL_INIT_IMAGE"
    docker tag toggle-vault-init:latest "$FULL_INIT_IMAGE"
    
    log_info "Pushing init image to ACR..."
    docker push "$FULL_INIT_IMAGE"
    log_success "Init image pushed to ACR"
}

#==============================================================================
# Print Configuration Summary
#==============================================================================

print_config() {
    echo ""
    echo "=============================================="
    echo "  Toggle Vault Deployment Configuration"
    echo "=============================================="
    echo ""
    echo "Azure Region:          $REGION"
    echo "Resource Group:        $RESOURCE_GROUP"
    echo "AKS Cluster:           ${CLUSTER_NAME}-${REGION}"
    echo ""
    echo "Container Registry:    ${ACR_NAME}.azurecr.io"
    echo "Main Image Tar:        ${IMAGE_TAR}"
    echo "Init Image Tar:        ${INIT_IMAGE_TAR}"
    echo "Image Tag:             ${IMAGE_TAG}"
    if [[ "$SKIP_IMAGE_PUSH" == true ]]; then
        echo "                       (skipping push - using existing)"
    fi
    echo ""
    echo "Storage Accounts:      ${#STORAGE_ACCOUNTS[@]} configured"
    for sa in "${STORAGE_ACCOUNTS[@]}"; do
        parse_storage_account "$sa"
        local sa_sub_display="${SA_SUBSCRIPTION:0:8}..."
        [[ -z "$SA_SUBSCRIPTION" ]] && sa_sub_display="(current)"
        echo "  - $SA_NAME"
        echo "      Resource Group: $SA_RG"
        echo "      Subscription:   $sa_sub_display"
        echo "      Container:      ${SA_CONTAINER:-<all>}"
        [[ -n "$SA_PREFIX" ]] && echo "      Prefix:         $SA_PREFIX"
    done
    echo ""
    echo "Sync Interval:         $SYNC_INTERVAL"
    echo ""
    echo "=============================================="
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY RUN - No resources will be created"
        exit 0
    fi
}

#==============================================================================
# Create Resource Group
#==============================================================================

create_resource_group() {
    log_info "Creating resource group: $RESOURCE_GROUP"
    
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$REGION" \
        --tags application=toggle-vault deployed-by=airgap-deploy.sh \
        --output none
    
    log_success "Resource group created"
}

#==============================================================================
# Create User-Assigned Managed Identity
#==============================================================================

create_managed_identity() {
    local IDENTITY_NAME="id-toggle-vault-${REGION}"
    
    log_info "Creating managed identity: $IDENTITY_NAME"
    
    # Check if identity already exists
    if az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
        log_success "Managed identity '$IDENTITY_NAME' already exists"
    else
        az identity create \
            --name "$IDENTITY_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$REGION" \
            --tags application=toggle-vault \
            --output none
        log_success "Managed identity created"
    fi
    
    # Get identity details
    IDENTITY_CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query clientId -o tsv)
    IDENTITY_PRINCIPAL_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv)
    IDENTITY_RESOURCE_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query id -o tsv)
    
    log_info "Managed Identity Client ID: $IDENTITY_CLIENT_ID"
    
    # Assign Storage Blob Data Contributor role for each storage account
    log_info "Assigning Storage Blob Data Contributor role on storage account(s)..."
    
    for sa in "${STORAGE_ACCOUNTS[@]}"; do
        parse_storage_account "$sa"
        
        log_info "  Assigning role for storage account: $SA_NAME"
        
        # Get storage account ID (may be cross-subscription)
        local STORAGE_ACCOUNT_ID
        if [[ -n "$SA_SUBSCRIPTION" ]]; then
            STORAGE_ACCOUNT_ID=$(az storage account show \
                --name "$SA_NAME" \
                --resource-group "$SA_RG" \
                --subscription "$SA_SUBSCRIPTION" \
                --query id -o tsv)
        else
            STORAGE_ACCOUNT_ID=$(az storage account show \
                --name "$SA_NAME" \
                --resource-group "$SA_RG" \
                --query id -o tsv)
        fi
        
        # Create role assignment (may be cross-subscription)
        az role assignment create \
            --role "Storage Blob Data Contributor" \
            --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
            --assignee-principal-type ServicePrincipal \
            --scope "$STORAGE_ACCOUNT_ID" \
            --output none 2>/dev/null || log_warn "Role assignment may already exist for $SA_NAME"
        
        log_success "  RBAC role assigned for $SA_NAME"
    done
    
    log_success "All RBAC roles assigned"
}

#==============================================================================
# Create AKS Cluster
#==============================================================================

create_aks_cluster() {
    local AKS_NAME="${CLUSTER_NAME}-${REGION}"
    
    log_info "Creating AKS cluster: $AKS_NAME (this may take 5-10 minutes)..."
    
    az aks create \
        --name "$AKS_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$REGION" \
        --node-count "$NODE_COUNT" \
        --node-vm-size "$NODE_SIZE" \
        --kubernetes-version "$K8S_VERSION" \
        --enable-oidc-issuer \
        --enable-workload-identity \
        --generate-ssh-keys \
        --attach-acr "$ACR_NAME" \
        --tags application=toggle-vault \
        --output none
    
    log_success "AKS cluster created"
    
    # Get OIDC issuer URL
    OIDC_ISSUER=$(az aks show --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP" --query "oidcIssuerProfile.issuerUrl" -o tsv)
    
    # Create federated credential
    local IDENTITY_NAME="id-toggle-vault-${REGION}"
    
    log_info "Creating federated identity credential..."
    
    az identity federated-credential create \
        --name "toggle-vault-federated" \
        --identity-name "$IDENTITY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --issuer "$OIDC_ISSUER" \
        --subject "system:serviceaccount:toggle-vault:toggle-vault-sa" \
        --audiences "api://AzureADTokenExchange" \
        --output none
    
    log_success "Federated credential created"
    
    # Get credentials
    log_info "Getting AKS credentials..."
    az aks get-credentials --name "$AKS_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing
    
    log_success "kubectl configured for cluster"
}

#==============================================================================
# Deploy Kubernetes Resources
#==============================================================================

deploy_kubernetes() {
    log_info "Deploying Kubernetes resources..."
    
    local IDENTITY_NAME="id-toggle-vault-${REGION}"
    local IDENTITY_CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query clientId -o tsv)
    local FULL_IMAGE="${ACR_NAME}.azurecr.io/toggle-vault:${IMAGE_TAG}"
    
    # Create namespace
    log_info "Creating namespace..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: toggle-vault
  labels:
    app.kubernetes.io/name: toggle-vault
EOF

    # Create service account with workload identity
    log_info "Creating service account..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: toggle-vault-sa
  namespace: toggle-vault
  annotations:
    azure.workload.identity/client-id: "${IDENTITY_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
    app.kubernetes.io/name: toggle-vault
EOF

    # Create ConfigMap
    log_info "Creating ConfigMap..."
    
    # Build storage_accounts YAML array
    local STORAGE_ACCOUNTS_YAML=""
    for sa in "${STORAGE_ACCOUNTS[@]}"; do
        parse_storage_account "$sa"
        
        # Build the YAML for this storage account
        STORAGE_ACCOUNTS_YAML+="      - name: \"${SA_NAME}\""$'\n'
        [[ -n "$SA_SUBSCRIPTION" ]] && STORAGE_ACCOUNTS_YAML+="        subscription_id: \"${SA_SUBSCRIPTION}\""$'\n'
        STORAGE_ACCOUNTS_YAML+="        resource_group: \"${SA_RG}\""$'\n'
        
        if [[ -n "$SA_CONTAINER" ]]; then
            STORAGE_ACCOUNTS_YAML+="        container: \"${SA_CONTAINER}\""$'\n'
        else
            STORAGE_ACCOUNTS_YAML+="        scan_all_containers: true"$'\n'
        fi
        
        [[ -n "$SA_PREFIX" ]] && STORAGE_ACCOUNTS_YAML+="        prefix: \"${SA_PREFIX}\""$'\n'
    done
    
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: toggle-vault-config
  namespace: toggle-vault
data:
  config.yaml: |
    azure:
      storage_accounts:
${STORAGE_ACCOUNTS_YAML}
      use_managed_identity: true

    sync:
      interval: ${SYNC_INTERVAL}
      patterns:
        - "*.yaml"
        - "*.yml"

    database:
      path: "/data/toggle-vault.db"

    server:
      port: 8080
      host: "0.0.0.0"
EOF

    # Create PVC
    log_info "Creating PersistentVolumeClaim..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: toggle-vault-data
  namespace: toggle-vault
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

    # Create Deployment
    log_info "Creating Deployment..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: toggle-vault
  namespace: toggle-vault
  labels:
    app: toggle-vault
    app.kubernetes.io/name: toggle-vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: toggle-vault
  template:
    metadata:
      labels:
        app: toggle-vault
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: toggle-vault-sa
      
      # Init container for cloud initialization (CA certs, cloud config)
      initContainers:
        - name: init-cloud
          image: ${ACR_NAME}.azurecr.io/toggle-vault-init:${IMAGE_TAG}
          imagePullPolicy: Always
          env:
            - name: AZURE_CLOUD
              value: "AzureUSGovernment"
            - name: AZURE_REGION
              value: "${REGION}"
            - name: CONFIG_FILE
              value: "/config/config.yaml"
            - name: CERT_OUTPUT_DIR
              value: "/shared/certs"
            - name: AZURE_CONFIG_DIR
              value: "/shared/azure"
          volumeMounts:
            - name: config
              mountPath: /config/config.yaml
              subPath: config.yaml
              readOnly: true
            - name: shared-data
              mountPath: /shared
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "128Mi"
      
      containers:
        - name: toggle-vault
          image: ${FULL_IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
              name: http
          env:
            - name: REQUESTS_CA_BUNDLE
              value: "/app/certs/ca-bundle.crt"
            - name: SSL_CERT_FILE
              value: "/app/certs/ca-bundle.crt"
            - name: CURL_CA_BUNDLE
              value: "/app/certs/ca-bundle.crt"
            - name: AZURE_CONFIG_DIR
              value: "/app/azure-config"
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
            - name: data
              mountPath: /data
            - name: shared-data
              mountPath: /app/certs
              subPath: certs
              readOnly: true
            - name: shared-data
              mountPath: /app/azure-config
              subPath: azure
              readOnly: true
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          livenessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /api/health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: toggle-vault-config
        - name: data
          persistentVolumeClaim:
            claimName: toggle-vault-data
        - name: shared-data
          emptyDir: {}
EOF

    # Create Service
    log_info "Creating Service..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: toggle-vault-service
  namespace: toggle-vault
  labels:
    app: toggle-vault
spec:
  type: LoadBalancer
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app: toggle-vault
EOF

    log_success "Kubernetes resources deployed"
}

#==============================================================================
# Wait for Deployment
#==============================================================================

wait_for_deployment() {
    log_info "Waiting for deployment to be ready..."
    
    kubectl rollout status deployment/toggle-vault -n toggle-vault --timeout=300s
    
    log_success "Deployment is ready"
}

#==============================================================================
# Get External IP
#==============================================================================

get_external_ip() {
    log_info "Waiting for external IP (this may take a few minutes)..."
    
    local max_attempts=30
    local attempt=0
    local external_ip=""
    
    while [[ $attempt -lt $max_attempts ]]; do
        external_ip=$(kubectl get svc toggle-vault-service -n toggle-vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$external_ip" ]]; then
            break
        fi
        
        attempt=$((attempt + 1))
        echo -n "."
        sleep 10
    done
    echo ""
    
    if [[ -z "$external_ip" ]]; then
        log_warn "External IP not yet assigned. Check later with:"
        log_warn "  kubectl get svc -n toggle-vault toggle-vault-service"
        EXTERNAL_IP="<pending>"
    else
        EXTERNAL_IP="$external_ip"
        log_success "External IP: $EXTERNAL_IP"
    fi
}

#==============================================================================
# Print Summary
#==============================================================================

print_summary() {
    echo ""
    echo "=============================================="
    echo "    Toggle Vault Deployment Complete!"
    echo "=============================================="
    echo ""
    echo "Cluster:            ${CLUSTER_NAME}-${REGION}"
    echo "Resource Group:     $RESOURCE_GROUP"
    echo ""
    echo "Storage Accounts:   ${#STORAGE_ACCOUNTS[@]} monitored"
    for sa in "${STORAGE_ACCOUNTS[@]}"; do
        parse_storage_account "$sa"
        echo "  - $SA_NAME (${SA_CONTAINER:-all containers})"
    done
    echo ""
    echo "----------------------------------------------"
    echo "Application URL:    http://${EXTERNAL_IP}:8080"
    echo "Health Check:       http://${EXTERNAL_IP}:8080/api/health"
    echo "----------------------------------------------"
    echo ""
    echo "Useful Commands:"
    echo "  kubectl get pods -n toggle-vault"
    echo "  kubectl logs -n toggle-vault -l app=toggle-vault"
    echo "  kubectl get svc -n toggle-vault"
    echo ""
}

#==============================================================================
# Main
#==============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║     Toggle Vault - Airgap Deployment       ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    
    parse_args "$@"
    check_prerequisites
    validate_resources
    print_config
    
    # Create Azure resources
    create_resource_group
    create_acr
    push_image
    create_managed_identity
    create_aks_cluster
    
    # Deploy application
    deploy_kubernetes
    wait_for_deployment
    get_external_ip
    print_summary
}

main "$@"
