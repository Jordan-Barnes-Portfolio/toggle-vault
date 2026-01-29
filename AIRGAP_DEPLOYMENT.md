# Toggle Vault - Airgap Deployment Guide

This guide walks you through deploying Toggle Vault in an airgapped environment.

## What You Need

You should have received these files:
- `toggle-vault-image.tar` - The Docker image
- `AIRGAP_DEPLOYMENT.md` - This guide
- `airgap-deploy.sh` - The deployment script

**The deployment script creates ALL required Azure resources** including:
- Azure Container Registry (ACR)
- Azure Kubernetes Service (AKS) cluster
- Managed Identity with storage permissions
- All Kubernetes resources

## Prerequisites

Before starting, ensure you have:

| Requirement | How to Check | Install If Missing |
|-------------|--------------|-------------------|
| Azure CLI | `az --version` | [Install Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) |
| Docker | `docker --version` | [Install Docker](https://docs.docker.com/get-docker/) |
| kubectl | `kubectl version --client` | `az aks install-cli` |

You also need:
- An Azure subscription with permissions to create resources
- One or more existing **Azure Storage Account(s)** with blob container(s) containing your YAML files
- For cross-subscription storage accounts: permissions to create role assignments in those subscriptions

---

## Step 1: Gather Your Azure Information

Before running the script, collect this information for each storage account:

### Required Information (per storage account)

| Setting | Description | Example |
|---------|-------------|---------|
| **Azure Region** | Where to deploy Toggle Vault | `usseceast`, `ussecwest` |
| **Storage Account Name** | Name of the storage account | `mystorageaccount` |
| **Resource Group** | Resource group containing the storage account | `rg-storage` |
| **Subscription ID** | Only if cross-subscription (optional) | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |

### Optional Information

| Setting | Description | Example |
|---------|-------------|---------|
| **ACR Name** | Custom ACR name (auto-generated if not specified) | `mycompanyacr` |
| **Container Name** | Limit to a specific container (default: scan all) | `toggles` |
| **Prefix** | Only watch files with this path prefix | `config/` |

### How to Find These Values

**Find storage accounts in current subscription:**
```bash
az storage account list --query "[].{Name:name, ResourceGroup:resourceGroup}" -o table
```

**Find storage accounts in a different subscription:**
```bash
az storage account list --subscription <subscription-id> --query "[].{Name:name, ResourceGroup:resourceGroup}" -o table
```

**List containers in a storage account:**
```bash
az storage container list --account-name <storage-account-name> --query "[].name" -o table
```

---

## Step 2: Login to Azure

```bash
az login
```

If you have multiple subscriptions, set the correct one:
```bash
# List subscriptions
az account list --query "[].{Name:name, ID:id}" -o table

# Set the subscription
az account set --subscription "<subscription-id>"
```

---

## Step 3: Run the Deployment Script

Place the script and image tar in the same directory:
```
./
├── airgap-deploy.sh
└── toggle-vault-image.tar
```

### 3.1 Make the script executable

```bash
chmod +x airgap-deploy.sh
```

### 3.2 Run the deployment

**Single storage account (same subscription):**
```bash
./airgap-deploy.sh \
  --region eastus \
  --storage-account "mystorageaccount::rg-storage"
```

**Multiple storage accounts:**
```bash
./airgap-deploy.sh \
  --region eastus \
  --storage-account "storage1::rg-storage1" \
  --storage-account "storage2::rg-storage2"
```

**Cross-subscription storage accounts:**
```bash
./airgap-deploy.sh \
  --region eastus \
  --storage-account "storage1:11111111-1111-1111-1111-111111111111:rg-storage1" \
  --storage-account "storage2:22222222-2222-2222-2222-222222222222:rg-storage2"
```

The script will automatically:
1. Create a resource group for Toggle Vault
2. Create an Azure Container Registry
3. Load and push the Docker image
4. Create an AKS cluster with Workload Identity
5. Create a Managed Identity with storage permissions (including cross-subscription RBAC)
6. Deploy the application

This typically takes **10-15 minutes**.

### Storage Account Format

The `--storage-account` option uses colon-separated values:

```
name:subscription:resource_group:container:prefix
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Storage account name |
| `subscription` | No | Subscription ID (empty = current subscription) |
| `resource_group` | Yes | Resource group containing the storage account |
| `container` | No | Specific container (empty = scan all) |
| `prefix` | No | File path prefix filter |

**Examples:**
- `myaccount::myrg` - Same subscription, scan all containers
- `myaccount::myrg:toggles` - Same subscription, specific container
- `myaccount:sub-id:myrg` - Cross-subscription, scan all containers
- `myaccount:sub-id:myrg:toggles:config/` - Full specification

### Full List of Options

| Option | Required | Description | Default |
|--------|----------|-------------|---------|
| `--region` | Yes | Azure region | - |
| `--storage-account` | Yes | Storage account (can be specified multiple times) | - |
| `--acr-name` | No | ACR name (created if not exists) | `acrtogvault<region>` |
| `--resource-group` | No | Resource group for Toggle Vault | `rg-toggle-vault-<region>` |
| `--cluster-name` | No | AKS cluster name | `aks-toggle-vault` |
| `--node-size` | No | VM size for AKS nodes | `Standard_B2s` |
| `--image-tar` | No | Path to Docker image tar | `toggle-vault-image.tar` |
| `--image-tag` | No | Docker image tag | `latest` |
| `--sync-interval` | No | How often to check for changes | `60s` |
| `--skip-image-push` | No | Skip image push (use existing in ACR) | - |
| `--dry-run` | No | Show what would be created | - |

### Example with All Options

```bash
./airgap-deploy.sh \
  --region eastus \
  --storage-account "storage1::rg-storage1:toggles" \
  --storage-account "storage2:sub-id-2:rg-storage2" \
  --acr-name mycompanyacr \
  --resource-group rg-togglevault-prod \
  --cluster-name aks-togglevault \
  --node-size Standard_B2ms \
  --sync-interval 30s
```

---

## Step 4: Verify the Deployment

### 4.1 Check pod status

```bash
kubectl get pods -n toggle-vault
```

Expected output:
```
NAME                            READY   STATUS    RESTARTS   AGE
toggle-vault-xxxxxxxxxx-xxxxx   1/1     Running   0          2m
```

### 4.2 Check the logs

```bash
kubectl logs -n toggle-vault -l app=toggle-vault
```

You should see:
```
Starting Toggle Vault...
Connecting to storage account: mystorageaccount
Starting sync cycle...
```

### 4.3 Get the application URL

```bash
kubectl get svc -n toggle-vault toggle-vault-service
```

Look for the `EXTERNAL-IP` column. Access the app at:
```
http://<EXTERNAL-IP>:8080
```

---

## Step 5: Test the Application

1. Open `http://<EXTERNAL-IP>:8080` in your browser
2. You should see the Toggle Vault UI
3. Your YAML files from the blob container should appear in the sidebar
4. Click a file to view its version history

### Health Check

```bash
curl http://<EXTERNAL-IP>:8080/api/health
```

Expected response:
```json
{"status":"healthy"}
```

---

## Troubleshooting

### Problem: Pod is stuck in "Pending" state

**Check events:**
```bash
kubectl describe pod -n toggle-vault -l app=toggle-vault
```

**Common causes:**
- AKS node pool is scaling up (wait a few minutes)
- Insufficient resources (try a larger `--node-size`)

### Problem: Pod is in "ImagePullBackOff" state

**Check the image name:**
```bash
kubectl describe pod -n toggle-vault -l app=toggle-vault | grep "Image:"
```

**Verify the image exists in ACR:**
```bash
az acr repository show-tags --name <acr-name> --repository toggle-vault
```

**Verify AKS can access ACR:**
```bash
az aks check-acr --name <cluster-name> --resource-group <rg-name> --acr <acr-name>.azurecr.io
```

### Problem: App starts but shows no files

**Check the logs for errors:**
```bash
kubectl logs -n toggle-vault -l app=toggle-vault
```

**Common causes:**
- Wrong storage account name or container
- Managed identity doesn't have permissions (see below)

**Verify RBAC permissions:**
```bash
# Get the managed identity
IDENTITY_NAME=$(az identity list --resource-group <rg-name> --query "[?contains(name, 'toggle-vault')].name" -o tsv)

# Check role assignments
az role assignment list --assignee $(az identity show -n $IDENTITY_NAME -g <rg-name> --query principalId -o tsv) --all
```

The identity should have `Storage Blob Data Contributor` on the storage account.

### Problem: Cannot restore files (403 error)

The managed identity needs write access. Verify it has `Storage Blob Data Contributor` (not just `Reader`).

---

## Updating Toggle Vault

To deploy a new version:

### 1. Load and push the new image

```bash
docker load -i toggle-vault-image-v2.tar
docker tag toggle-vault:latest <acr-name>.azurecr.io/toggle-vault:v2
docker push <acr-name>.azurecr.io/toggle-vault:v2
```

### 2. Update the deployment

```bash
kubectl set image deployment/toggle-vault \
  toggle-vault=<acr-name>.azurecr.io/toggle-vault:v2 \
  -n toggle-vault
```

### 3. Watch the rollout

```bash
kubectl rollout status deployment/toggle-vault -n toggle-vault
```

---

## Cleanup

To remove all Toggle Vault resources:

```bash
# Delete the resource group (removes everything)
az group delete --name rg-toggle-vault-<region> --yes

# Or just delete Kubernetes resources (keeps infrastructure)
kubectl delete namespace toggle-vault
```

---

## Architecture Reference

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Azure Subscription                           │
│                                                                      │
│  ┌──────────────────────┐         ┌──────────────────────────────┐ │
│  │   Your Storage       │         │  Toggle Vault Resource Group │ │
│  │   Account            │         │                              │ │
│  │   ┌──────────────┐   │  RBAC   │  ┌────────────────────────┐ │ │
│  │   │ toggles/     │◄──┼─────────┼──│ Managed Identity       │ │ │
│  │   │  *.yaml      │   │         │  │ (Storage Blob Data     │ │ │
│  │   └──────────────┘   │         │  │  Contributor)          │ │ │
│  └──────────────────────┘         │  └───────────┬────────────┘ │ │
│                                   │              │ Workload     │ │
│                                   │              │ Identity     │ │
│                                   │              ▼              │ │
│                                   │  ┌────────────────────────┐ │ │
│                                   │  │ AKS Cluster            │ │ │
│                                   │  │  ┌──────────────────┐  │ │ │
│                                   │  │  │ toggle-vault pod │  │ │ │
│                                   │  │  │   (Port 8080)    │  │ │ │
│                                   │  │  └──────────────────┘  │ │ │
│                                   │  └────────────────────────┘ │ │
│                                   └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Support

If you encounter issues not covered here:

1. Collect logs: `kubectl logs -n toggle-vault -l app=toggle-vault > toggle-vault-logs.txt`
2. Collect events: `kubectl get events -n toggle-vault > toggle-vault-events.txt`
3. Contact your administrator with these files
