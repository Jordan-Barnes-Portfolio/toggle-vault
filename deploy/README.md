# Toggle Vault Deployment

This directory contains everything needed to deploy Toggle Vault to Azure Kubernetes Service (AKS) with proper Managed Identity authentication.

## Directory Structure

```
deploy/
├── arm/                          # ARM Templates
│   ├── main.json                 # Main deployment template
│   ├── parameters.json           # Base parameters (region-agnostic)
│   └── modules/
│       ├── aks.json              # AKS cluster
│       ├── identity.json         # Managed Identity
│       └── rbac.json             # Role assignments
├── kubernetes/
│   ├── base/                     # Base Kubernetes manifests
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── pvc.yaml
│   └── overlays/                 # Region-specific overrides
│       ├── eastus/
│       │   └── manifest.yaml
│       ├── westus2/
│       │   └── manifest.yaml
│       └── template/
│           └── manifest.yaml     # Template for new regions
├── scripts/
│   ├── deploy.sh                 # Main deployment script
│   ├── destroy.sh                # Cleanup script
│   └── utils.sh                  # Helper functions
└── README.md                     # This file
```

## Prerequisites

1. **Azure CLI** installed and logged in (`az login`)
2. **kubectl** installed
3. **Existing Storage Account** with blob container for toggle files
4. **Permissions** to create resources in your Azure subscription

## Quick Start

### 1. Configure Your Region

Copy the template and customize for your region:

```bash
cp deploy/kubernetes/overlays/template/manifest.yaml deploy/kubernetes/overlays/myregion/manifest.yaml
```

Edit the manifest with your region-specific values:
- Storage account name
- Container name
- Resource naming conventions
- Any region-specific settings

### 2. Deploy Infrastructure

```bash
cd deploy/scripts

# Deploy to a specific region
./deploy.sh \
  --resource-group "rg-toggle-vault-eastus" \
  --location "eastus" \
  --storage-account "mystorageaccount" \
  --storage-container "toggles" \
  --region-config "../kubernetes/overlays/eastus/manifest.yaml"
```

### 3. Verify Deployment

```bash
# Get the external IP
kubectl get svc -n toggle-vault toggle-vault-service

# Access the UI
curl http://<EXTERNAL-IP>:8080/api/health
```

## Deployment Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--resource-group` | Yes | Azure resource group name |
| `--location` | Yes | Azure region (e.g., eastus, westus2) |
| `--storage-account` | Yes | Existing storage account name |
| `--storage-container` | Yes | Blob container with toggle files |
| `--region-config` | Yes | Path to region-specific manifest |
| `--cluster-name` | No | AKS cluster name (default: aks-toggle-vault) |
| `--node-count` | No | AKS node count (default: 1) |
| `--node-size` | No | AKS node VM size (default: Standard_B2s) |

## What Gets Created

1. **AKS Cluster** - Managed Kubernetes cluster
2. **User-Assigned Managed Identity** - For Toggle Vault to access blob storage
3. **Federated Identity Credential** - Links K8s service account to managed identity
4. **RBAC Role Assignment** - Grants "Storage Blob Data Contributor" to the identity
5. **Kubernetes Resources**:
   - Namespace: `toggle-vault`
   - Deployment with the Toggle Vault container
   - LoadBalancer Service
   - ConfigMap with configuration
   - PersistentVolumeClaim for SQLite database

## Adding a New Region

1. Create a new overlay directory:
   ```bash
   mkdir -p deploy/kubernetes/overlays/newregion
   ```

2. Copy and edit the manifest template:
   ```bash
   cp deploy/kubernetes/overlays/template/manifest.yaml deploy/kubernetes/overlays/newregion/manifest.yaml
   ```

3. Update the manifest with region-specific values

4. Run the deployment script with the new region config

## Cleanup

To remove all deployed resources:

```bash
./deploy/scripts/destroy.sh \
  --resource-group "rg-toggle-vault-eastus"
```

This will:
- Delete the AKS cluster
- Delete the Managed Identity
- Remove RBAC assignments
- Delete the resource group

**Note**: This does NOT delete your storage account or toggle files.
