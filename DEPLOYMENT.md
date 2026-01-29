# Toggle Vault Deployment Guide

This guide walks you through deploying Toggle Vault to Azure Kubernetes Service (AKS) from scratch.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Step 1: Install Required Tools](#step-1-install-required-tools)
3. [Step 2: Clone and Configure](#step-2-clone-and-configure)
4. [Step 3: Azure Authentication](#step-3-azure-authentication)
5. [Step 4: Create Azure Resources](#step-4-create-azure-resources)
6. [Step 5: Build and Push Container Image](#step-5-build-and-push-container-image)
7. [Step 6: Deploy AKS Infrastructure](#step-6-deploy-aks-infrastructure)
8. [Step 7: Deploy Application to Kubernetes](#step-7-deploy-application-to-kubernetes)
9. [Step 8: Verify Deployment](#step-8-verify-deployment)
10. [Step 9: Access the Application](#step-9-access-the-application)
11. [Troubleshooting](#troubleshooting)
12. [Cleanup](#cleanup)

---

## Prerequisites

Before you begin, ensure you have:

- An Azure subscription with permissions to create resources
- An existing storage account with toggle files, OR you'll create one during deployment
- Network access to Azure (or appropriate airgap configuration)

---

## Step 1: Install Required Tools

### macOS (using Homebrew)

```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Azure CLI
brew install azure-cli

# Install kubectl
brew install kubectl

# Install yq (YAML processor)
brew install yq

# Install jq (JSON processor)
brew install jq

# Verify installations
az --version
kubectl version --client
yq --version
jq --version
```

### Windows (using winget)

```powershell
# Install Azure CLI
winget install Microsoft.AzureCLI

# Install kubectl
winget install Kubernetes.kubectl

# Install yq
winget install MikeFarah.yq

# Install jq
winget install jqlang.jq
```

### Linux (Ubuntu/Debian)

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install yq
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
sudo chmod +x /usr/bin/yq

# Install jq
sudo apt-get install jq
```

---

## Step 2: Clone and Configure

### 2.1 Clone the Repository

```bash
git clone <repository-url> toggle-vault
cd toggle-vault
```

### 2.2 Create Your Regional Configuration

```bash
# Choose your region (e.g., eastus, westus2, centralus)
REGION="eastus"

# Create regional configuration directory
mkdir -p deploy/kubernetes/overlays/$REGION

# Copy the template
cp deploy/kubernetes/overlays/template/manifest.yaml deploy/kubernetes/overlays/$REGION/manifest.yaml
```

### 2.3 Edit the Regional Configuration

Open `deploy/kubernetes/overlays/$REGION/manifest.yaml` and update these values:

```yaml
# Required changes:
region: "eastus"                              # Your Azure region
azure:
  resourceGroup: "rg-toggle-vault-eastus"     # Your resource group name
  storageAccount:
    name: "yourstorageaccount"                # Your storage account name
    resourceGroup: ""                         # Leave empty if same as above
    
    # Container scope - choose ONE of the following:
    
    # Option A: Single container
    container: "toggles"
    
    # Option B: Multiple specific containers
    # containers:
    #   - "toggles"
    #   - "config"
    #   - "settings"
    
    # Option C: Scan ALL containers in the storage account
    # scanAllContainers: true
    
container:
  registry: "youracr.azurecr.io"              # Your ACR registry
  image: "toggle-vault"
  tag: "v1"
```

**Container Scope Options:**

| Option | Use Case |
|--------|----------|
| `container: "name"` | Monitor a single container (default) |
| `containers: [list]` | Monitor specific containers only |
| `scanAllContainers: true` | Monitor entire storage account |

---

## Step 3: Azure Authentication

### 3.1 Login to Azure

```bash
# Interactive login (opens browser)
az login

# Or use device code for headless environments
az login --use-device-code
```

### 3.2 Set Your Subscription (if you have multiple)

```bash
# List subscriptions
az account list --output table

# Set the subscription you want to use
az account set --subscription "<subscription-id-or-name>"

# Verify
az account show
```

### 3.3 Register Required Providers

```bash
# Register providers (only needed once per subscription)
az provider register --namespace Microsoft.ContainerRegistry
az provider register --namespace Microsoft.ContainerService

# Wait for registration (check status)
az provider show -n Microsoft.ContainerRegistry --query "registrationState"
az provider show -n Microsoft.ContainerService --query "registrationState"
```

---

## Step 4: Create Azure Resources

### 4.1 Set Environment Variables

```bash
# Configure these for your environment
export REGION="eastus"
export RESOURCE_GROUP="rg-toggle-vault-$REGION"
export STORAGE_ACCOUNT="sttoggles$(date +%s | tail -c 6)"  # Unique name
export ACR_NAME="acrtogglevault$(date +%s | tail -c 5)"    # Unique name
export CONTAINER_NAME="toggles"
```

### 4.2 Create Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $REGION \
  --tags application=toggle-vault environment=prod
```

### 4.3 Create Storage Account (Skip if using existing)

```bash
# Create storage account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $REGION \
  --sku Standard_LRS \
  --kind StorageV2

# Create blob container
az storage container create \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode key
```

### 4.4 Upload Sample Toggle Files (Optional)

```bash
# Upload sample files if you have them
az storage blob upload \
  --container-name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --file sample-toggles/feature-flags.yaml \
  --name feature-flags.yaml \
  --auth-mode key

az storage blob upload \
  --container-name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --file sample-toggles/app-settings.yaml \
  --name app-settings.yaml \
  --auth-mode key
```

### 4.5 Create Azure Container Registry

```bash
az acr create \
  --resource-group $RESOURCE_GROUP \
  --name $ACR_NAME \
  --sku Basic \
  --location $REGION

# Get the login server
export ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
echo "ACR Login Server: $ACR_LOGIN_SERVER"
```

---

## Step 5: Build and Push Container Image

### 5.1 Build Using ACR Tasks (Recommended)

This builds the image in Azure, no local Docker required:

```bash
az acr build \
  --registry $ACR_NAME \
  --image toggle-vault:v1 \
  --file Dockerfile \
  .
```

### 5.2 Alternative: Build Locally and Push

If you prefer to build locally:

```bash
# Login to ACR
az acr login --name $ACR_NAME

# Build locally
docker build -t $ACR_LOGIN_SERVER/toggle-vault:v1 .

# Push to ACR
docker push $ACR_LOGIN_SERVER/toggle-vault:v1
```

---

## Step 6: Deploy AKS Infrastructure

### 6.1 Deploy ARM Template

This creates:
- AKS cluster with Workload Identity enabled
- User-Assigned Managed Identity
- Federated Identity Credential
- RBAC role assignment for blob storage access

```bash
# Deploy infrastructure
az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --template-file deploy/arm/main.json \
  --parameters \
    location=$REGION \
    environmentName=prod \
    clusterName=aks-toggle-vault \
    nodeCount=1 \
    nodeVmSize=Standard_B2s \
    kubernetesVersion=1.32 \
    storageAccountName=$STORAGE_ACCOUNT \
    storageAccountResourceGroup=$RESOURCE_GROUP \
    managedIdentityName=toggle-vault-identity
```

### 6.2 Capture Deployment Outputs

```bash
# Get the outputs
export AKS_NAME="aks-toggle-vault-$REGION"
export MANAGED_IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name "toggle-vault-identity-$REGION" \
  --query clientId -o tsv)

echo "AKS Cluster: $AKS_NAME"
echo "Managed Identity Client ID: $MANAGED_IDENTITY_CLIENT_ID"
```

### 6.3 Get AKS Credentials

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --overwrite-existing

# Verify connection
kubectl get nodes
```

### 6.4 Attach ACR to AKS

```bash
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --attach-acr $ACR_NAME
```

---

## Step 7: Deploy Application to Kubernetes

### 7.1 Create Namespace

```bash
kubectl apply -f deploy/kubernetes/base/namespace.yaml
```

### 7.2 Create Service Account

```bash
export MANAGED_IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $RESOURCE_GROUP \
  --name "toggle-vault-identity-$REGION" \
  --query clientId -o tsv)

envsubst < deploy/kubernetes/base/serviceaccount.yaml | kubectl apply -f -
```

### 7.3 Create ConfigMap

```bash
export STORAGE_ACCOUNT_NAME=$STORAGE_ACCOUNT
export STORAGE_CONTAINER_NAME=$CONTAINER_NAME
export STORAGE_PREFIX=""
export SYNC_INTERVAL="60s"

envsubst < deploy/kubernetes/base/configmap.yaml | kubectl apply -f -
```

### 7.4 Create Persistent Volume Claim

```bash
kubectl apply -f deploy/kubernetes/base/pvc.yaml
```

### 7.5 Create Deployment

```bash
export CONTAINER_REGISTRY=$ACR_LOGIN_SERVER
export IMAGE_TAG="v1"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: toggle-vault
  namespace: toggle-vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: toggle-vault
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: toggle-vault
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: toggle-vault-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: toggle-vault
          image: $CONTAINER_REGISTRY/toggle-vault:$IMAGE_TAG
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /app/config.yaml
              subPath: config.yaml
              readOnly: true
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /api/health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /api/health
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
      volumes:
        - name: config
          configMap:
            name: toggle-vault-config
        - name: data
          persistentVolumeClaim:
            claimName: toggle-vault-data
EOF
```

### 7.6 Create Service

```bash
kubectl apply -f deploy/kubernetes/base/service.yaml
```

### 7.7 Wait for Deployment

```bash
kubectl rollout status deployment/toggle-vault -n toggle-vault --timeout=120s
```

---

## Step 8: Verify Deployment

### 8.1 Check Pod Status

```bash
kubectl get pods -n toggle-vault
```

Expected output:
```
NAME                            READY   STATUS    RESTARTS   AGE
toggle-vault-xxxxxxxxx-xxxxx   1/1     Running   0          1m
```

### 8.2 Check Logs

```bash
kubectl logs -n toggle-vault -l app.kubernetes.io/name=toggle-vault
```

Expected output should show:
```
Toggle Vault starting...
Storage Account: yourstorageaccount, Container: toggles
Database initialized at /data/toggle-vault.db
Azure Blob client initialized
Syncer started with interval 1m0s
Starting sync cycle...
Found X blobs matching patterns
```

### 8.3 Get External IP

```bash
kubectl get svc -n toggle-vault toggle-vault-service
```

Wait until EXTERNAL-IP is assigned (may take 1-2 minutes):
```
NAME                   TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
toggle-vault-service   LoadBalancer   10.0.x.x      20.xx.xx.xx    8080:xxxxx/TCP
```

### 8.4 Test Health Endpoint

```bash
EXTERNAL_IP=$(kubectl get svc toggle-vault-service -n toggle-vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$EXTERNAL_IP:8080/api/health
```

Expected output:
```json
{"status":"healthy"}
```

---

## Step 9: Access the Application

### 9.1 Get the Application URL

```bash
EXTERNAL_IP=$(kubectl get svc toggle-vault-service -n toggle-vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Toggle Vault URL: http://$EXTERNAL_IP:8080"
```

### 9.2 Open in Browser

Navigate to `http://<EXTERNAL-IP>:8080` in your web browser.

### 9.3 Using the Application

1. **View Files**: The left sidebar shows all tracked toggle files
2. **View History**: Click a file to see its version history
3. **Compare Versions**: Click "Diff" to compare two versions
4. **Switch Diff View**: Use "Unified" or "Side by Side" toggle
5. **Restore Version**: Click "Restore" to revert to a previous version

---

## Troubleshooting

### Pod Not Starting

```bash
# Check pod events
kubectl describe pod -n toggle-vault -l app.kubernetes.io/name=toggle-vault

# Check logs
kubectl logs -n toggle-vault -l app.kubernetes.io/name=toggle-vault --previous
```

### Authentication Errors

If you see "DefaultAzureCredential authentication failed":

1. Verify the federated identity credential exists:
```bash
az identity federated-credential list \
  --identity-name "toggle-vault-identity-$REGION" \
  --resource-group $RESOURCE_GROUP
```

2. Verify the service account has the correct annotation:
```bash
kubectl get sa toggle-vault-sa -n toggle-vault -o yaml | grep azure.workload.identity
```

3. Verify the pod has the workload identity label:
```bash
kubectl get pod -n toggle-vault -l app.kubernetes.io/name=toggle-vault -o yaml | grep "azure.workload.identity/use"
```

### Cannot Access Storage Account

Verify RBAC role assignment:
```bash
az role assignment list \
  --scope "/subscriptions/<sub-id>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT" \
  --query "[?contains(principalName, 'toggle-vault')]"
```

### Image Pull Errors

Verify ACR is attached to AKS:
```bash
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $AKS_NAME \
  --query "identityProfile.kubeletidentity.clientId" -o tsv
```

---

## Cleanup

To remove all deployed resources:

### Option 1: Delete Entire Resource Group (Destructive)

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

### Option 2: Delete Individual Resources

```bash
# Delete Kubernetes resources
kubectl delete namespace toggle-vault

# Delete AKS cluster
az aks delete --resource-group $RESOURCE_GROUP --name $AKS_NAME --yes --no-wait

# Delete managed identity
az identity delete --resource-group $RESOURCE_GROUP --name "toggle-vault-identity-$REGION"

# Delete ACR (optional)
az acr delete --resource-group $RESOURCE_GROUP --name $ACR_NAME --yes

# Keep storage account with your toggle files
```

---

## Quick Reference

### Key Commands

| Action | Command |
|--------|---------|
| View pods | `kubectl get pods -n toggle-vault` |
| View logs | `kubectl logs -n toggle-vault -l app.kubernetes.io/name=toggle-vault -f` |
| Restart app | `kubectl rollout restart deployment/toggle-vault -n toggle-vault` |
| Get external IP | `kubectl get svc toggle-vault-service -n toggle-vault` |
| Force sync | Restart the pod to trigger immediate sync |

### Environment Variables Summary

| Variable | Description | Example |
|----------|-------------|---------|
| REGION | Azure region | eastus |
| RESOURCE_GROUP | Resource group name | rg-toggle-vault-eastus |
| STORAGE_ACCOUNT | Storage account name | sttoggles123456 |
| ACR_NAME | Container registry name | acrtogglevault12345 |
| AKS_NAME | AKS cluster name | aks-toggle-vault-eastus |

---

## Next Steps

1. **Add DNS**: Configure Azure DNS or external DNS for a friendly URL
2. **Enable HTTPS**: Add an ingress controller with TLS
3. **Set up Monitoring**: Integrate with Azure Monitor or Prometheus
4. **Multi-Region**: Deploy to additional regions using the overlay pattern
