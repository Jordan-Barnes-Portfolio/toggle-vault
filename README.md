# Toggle Vault

A Git-blame style version control system for YAML toggle files stored in Azure Blob Storage. Toggle Vault monitors your blob storage for changes, tracks version history, and provides an intuitive web UI for browsing history, viewing diffs, and restoring previous versions.

## Features

- **Automatic Change Detection**: Periodically polls Azure Blob Storage for file changes
- **Version History**: Stores complete version history for all tracked files
- **Change Types**: Tracks created, modified, and deleted events
- **Web UI**: Modern, responsive interface for browsing files and history
- **Diff Viewer**: Unified and side-by-side diff comparison with syntax highlighting
- **One-Click Restore**: Restore any previous version directly to blob storage
- **Airgap Friendly**: Runs entirely on-premises with no external dependencies
- **Azure Native**: Uses Workload Identity for secure, secretless authentication

> **New to Toggle Vault?** See the [Step-by-Step Deployment Guide](DEPLOYMENT.md) for detailed instructions.

## Quick Start

### Prerequisites

- Go 1.21 or later
- Azure Storage Account with blob container
- One of the following authentication methods:
  - Connection string
  - SAS token
  - Service principal credentials
  - Managed identity (when running in Azure)

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/toggle-vault.git
cd toggle-vault

# Build the application
go build -o toggle-vault ./cmd/toggle-vault

# Or install directly
go install ./cmd/toggle-vault
```

### Configuration

1. Copy the example configuration:

```bash
cp config.yaml config.local.yaml
```

2. Edit `config.local.yaml` with your Azure Storage settings:

```yaml
azure:
  storage_account: "yourstorageaccount"
  container: "your-container"
  connection_string: "${AZURE_STORAGE_CONNECTION_STRING}"
  prefix: "toggles/"  # Optional: only watch files under this prefix

sync:
  interval: 30s
  patterns:
    - "*.yaml"
    - "*.yml"

database:
  path: "./toggle-vault.db"

server:
  port: 8080
  host: "0.0.0.0"
```

3. Set up authentication (choose one):

**Option A: Connection String**
```bash
export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=..."
```

**Option B: SAS Token**
```yaml
azure:
  sas_token: "${AZURE_STORAGE_SAS_TOKEN}"
```

**Option C: Service Principal**
```yaml
azure:
  tenant_id: "${AZURE_TENANT_ID}"
  client_id: "${AZURE_CLIENT_ID}"
  client_secret: "${AZURE_CLIENT_SECRET}"
```

**Option D: Managed Identity**
```yaml
azure:
  use_managed_identity: true
```

### Running

```bash
# Run with default config
./toggle-vault

# Run with custom config
./toggle-vault -config config.local.yaml
```

Open http://localhost:8080 in your browser.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Toggle Vault                            │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Blob Syncer │───>│   SQLite DB  │<───│   REST API   │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│         │                                       │           │
│         │                                       │           │
│         ▼                                       ▼           │
│  ┌──────────────┐                       ┌──────────────┐   │
│  │ Azure Blob   │                       │   Web UI     │   │
│  │   Storage    │                       │              │   │
│  └──────────────┘                       └──────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Components

1. **Blob Syncer**: Polls Azure Blob Storage at configurable intervals, detects changes using ETags and content hashes, and records versions.

2. **SQLite Database**: Stores file metadata and version history. Uses WAL mode for better concurrent access.

3. **REST API**: Provides endpoints for querying files, versions, generating diffs, and restoring versions.

4. **Web UI**: Single-page application for browsing files, viewing history, comparing versions, and performing restores.

## API Reference

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/files` | List all tracked files |
| GET | `/api/files/{path}` | Get file details |
| GET | `/api/files/{path}/versions` | Get version history |
| GET | `/api/files/{path}/versions/{id}` | Get specific version |
| GET | `/api/files/{path}/diff/{v1}/{v2}` | Compare two versions |
| POST | `/api/files/{path}/restore/{id}` | Restore a version |

### Example Requests

**List files:**
```bash
curl http://localhost:8080/api/files
```

**Get version history:**
```bash
curl http://localhost:8080/api/files/config/toggles.yaml/versions
```

**Compare versions:**
```bash
curl http://localhost:8080/api/files/config/toggles.yaml/diff/5/6
```

**Restore a version:**
```bash
curl -X POST http://localhost:8080/api/files/config/toggles.yaml/restore/5
```

## Development

### Project Structure

```
toggle-vault/
├── cmd/
│   └── toggle-vault/
│       └── main.go              # Entry point
├── internal/
│   ├── api/                     # REST API handlers
│   ├── blob/                    # Azure Blob client
│   ├── config/                  # Configuration loading
│   ├── diff/                    # Diff generation
│   ├── store/                   # SQLite database
│   └── syncer/                  # Change detection
├── web/
│   ├── static/                  # Frontend assets
│   └── embed.go                 # Embedded files
├── config.yaml                  # Example config
├── go.mod
└── README.md
```

### Building

```bash
# Build for current platform
go build -o toggle-vault ./cmd/toggle-vault

# Build for Linux (for containerized deployments)
GOOS=linux GOARCH=amd64 go build -o toggle-vault-linux ./cmd/toggle-vault
```

### Running Tests

```bash
go test ./...
```

## Deployment to Azure

Toggle Vault includes a complete deployment solution for Azure Kubernetes Service (AKS) with Managed Identity authentication.

### Quick Start Deployment

1. **Setup deployment scripts:**
   ```bash
   cd deploy/scripts
   chmod +x *.sh
   ./setup.sh
   ```

2. **Create your regional configuration:**
   ```bash
   cp ../kubernetes/overlays/template/manifest.yaml ../kubernetes/overlays/myregion/manifest.yaml
   # Edit the manifest with your values
   ```

3. **Login to Azure:**
   ```bash
   az login
   ```

4. **Deploy:**
   ```bash
   ./deploy.sh --config ../kubernetes/overlays/myregion/manifest.yaml
   ```

This will:
- Create a resource group
- Deploy an AKS cluster with Workload Identity enabled
- Create a User-Assigned Managed Identity
- Configure federated credentials for the Kubernetes service account
- Assign Storage Blob Data Contributor role to access your storage account
- Deploy Toggle Vault to the cluster

### What Gets Deployed

```
Azure Resources:
├── Resource Group (rg-toggle-vault-<region>)
├── AKS Cluster (aks-toggle-vault-<region>)
│   ├── System Node Pool
│   └── Workload Identity enabled
├── User-Assigned Managed Identity (id-toggle-vault-<region>)
│   ├── Federated Identity Credential (for K8s service account)
│   └── RBAC: Storage Blob Data Contributor on your storage account

Kubernetes Resources:
├── Namespace: toggle-vault
├── ServiceAccount with Workload Identity annotation
├── ConfigMap with app configuration
├── PersistentVolumeClaim for SQLite database
├── Deployment
└── LoadBalancer Service
```

### Regional Configuration

The deployment uses region-specific manifest files located in `deploy/kubernetes/overlays/`:

```
deploy/kubernetes/overlays/
├── template/manifest.yaml    # Template for new regions
├── eastus/manifest.yaml      # East US configuration
└── westus2/manifest.yaml     # West US 2 configuration
```

Each manifest contains:
- Azure resource settings (resource group, storage account)
- Container registry settings
- AKS cluster configuration
- Application settings

### Prerequisites

- **Azure CLI** (`az`) - logged in with appropriate permissions
- **kubectl** - Kubernetes command-line tool
- **yq** - YAML processor (https://github.com/mikefarah/yq)
- **jq** - JSON processor
- **Existing Storage Account** with blob container containing your toggle files

### Docker (Local/Manual)

```dockerfile
FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY . .
RUN CGO_ENABLED=1 go build -o toggle-vault ./cmd/toggle-vault

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/toggle-vault .
COPY config.yaml .
EXPOSE 8080
CMD ["./toggle-vault"]
```

### Cleanup

To remove all deployed resources:

```bash
cd deploy/scripts
./destroy.sh --config ../kubernetes/overlays/myregion/manifest.yaml
```

Add `--delete-resource-group` to remove the entire resource group.

## Troubleshooting

### Common Issues

**"No Azure authentication method configured"**
- Ensure you have set one of: connection_string, sas_token, managed_identity, or service principal credentials.

**"Failed to list blobs"**
- Check that the storage account name and container name are correct.
- Verify your authentication credentials have the necessary permissions (Storage Blob Data Reader at minimum, plus Storage Blob Data Contributor for restore functionality).

**Database locked errors**
- The SQLite database uses WAL mode to minimize locking. If you see lock errors, ensure only one instance of Toggle Vault is accessing the database.

### Logs

Toggle Vault logs to stdout. Key log messages:

- `Starting sync cycle...` - Syncer is checking for changes
- `New file detected: <path>` - A new file was found
- `File modified: <path>` - An existing file was changed
- `File deleted: <path>` - A file was removed from blob storage

## License

MIT License - see LICENSE file for details.
