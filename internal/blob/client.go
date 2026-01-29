package blob

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/container"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob/service"
	"github.com/toggle-vault/internal/config"
)

// BlobInfo represents metadata about a blob
type BlobInfo struct {
	StorageAccount string // storage account this blob belongs to
	Container      string
	Path           string
	FullPath       string // storageaccount/container/path for unique identification across accounts
	ETag           string
	LastModified   time.Time
	Size           int64
}

// BlobContent represents the content and metadata of a blob
type BlobContent struct {
	BlobInfo
	Content     []byte
	ContentHash string
}

// StorageAccountClient wraps the Azure Blob SDK client for a single storage account
type StorageAccountClient struct {
	serviceClient  *service.Client
	credential     azcore.TokenCredential
	accountConfig  config.StorageAccountConfig
	authConfig     config.AzureConfig // For auth settings (shared across accounts)
}

// Client wraps multiple storage account clients
type Client struct {
	accounts   []*StorageAccountClient
	authConfig config.AzureConfig
}

// NewClient creates a new Azure Blob client that supports multiple storage accounts
func NewClient(cfg config.AzureConfig) (*Client, error) {
	storageAccounts := cfg.GetStorageAccounts()
	if len(storageAccounts) == 0 {
		return nil, fmt.Errorf("no storage accounts configured")
	}

	client := &Client{
		accounts:   make([]*StorageAccountClient, 0, len(storageAccounts)),
		authConfig: cfg,
	}

	// Create a client for each storage account
	for _, accountCfg := range storageAccounts {
		accountClient, err := newStorageAccountClient(accountCfg, cfg)
		if err != nil {
			return nil, fmt.Errorf("failed to create client for storage account '%s': %w", accountCfg.Name, err)
		}
		client.accounts = append(client.accounts, accountClient)
	}

	return client, nil
}

// newStorageAccountClient creates a client for a single storage account
func newStorageAccountClient(accountCfg config.StorageAccountConfig, authCfg config.AzureConfig) (*StorageAccountClient, error) {
	var serviceClient *service.Client
	var cred azcore.TokenCredential
	var err error

	serviceURL := accountCfg.GetServiceURL()

	switch authCfg.GetAuthMethod() {
	case "connection_string":
		serviceClient, err = service.NewClientFromConnectionString(authCfg.ConnectionString, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create client from connection string: %w", err)
		}

	case "sas_token":
		sasURL := serviceURL
		if !strings.HasPrefix(authCfg.SASToken, "?") {
			sasURL += "?"
		}
		sasURL += authCfg.SASToken
		serviceClient, err = service.NewClientWithNoCredential(sasURL, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create client with SAS token: %w", err)
		}

	case "managed_identity":
		cred, err = azidentity.NewDefaultAzureCredential(nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create default azure credential: %w", err)
		}
		serviceClient, err = service.NewClient(serviceURL, cred, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create client with managed identity: %w", err)
		}

	case "service_principal":
		cred, err = azidentity.NewClientSecretCredential(authCfg.TenantID, authCfg.ClientID, authCfg.ClientSecret, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create service principal credential: %w", err)
		}
		serviceClient, err = service.NewClient(serviceURL, cred, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create client with service principal: %w", err)
		}

	default:
		return nil, fmt.Errorf("no valid authentication method configured")
	}

	return &StorageAccountClient{
		serviceClient: serviceClient,
		credential:    cred,
		accountConfig: accountCfg,
		authConfig:    authCfg,
	}, nil
}

// GetStorageAccountNames returns the names of all configured storage accounts
func (c *Client) GetStorageAccountNames() []string {
	names := make([]string, len(c.accounts))
	for i, account := range c.accounts {
		names[i] = account.accountConfig.Name
	}
	return names
}

// getAccountClient returns the client for a specific storage account
func (c *Client) getAccountClient(storageAccount string) (*StorageAccountClient, error) {
	for _, account := range c.accounts {
		if account.accountConfig.Name == storageAccount {
			return account, nil
		}
	}
	return nil, fmt.Errorf("storage account '%s' not configured", storageAccount)
}

// ListContainers lists all containers across all storage accounts
func (c *Client) ListContainers(ctx context.Context) (map[string][]string, error) {
	result := make(map[string][]string)

	for _, account := range c.accounts {
		containers, err := account.ListContainers(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to list containers in '%s': %w", account.accountConfig.Name, err)
		}
		result[account.accountConfig.Name] = containers
	}

	return result, nil
}

// ListContainers lists all containers in this storage account
func (s *StorageAccountClient) ListContainers(ctx context.Context) ([]string, error) {
	var containers []string

	pager := s.serviceClient.NewListContainersPager(nil)
	for pager.More() {
		resp, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to list containers: %w", err)
		}

		for _, cont := range resp.ContainerItems {
			if cont.Name != nil {
				containers = append(containers, *cont.Name)
			}
		}
	}

	return containers, nil
}

// GetContainersToScan returns the list of containers to scan based on config
func (s *StorageAccountClient) GetContainersToScan(ctx context.Context) ([]string, error) {
	if s.accountConfig.ShouldScanAllContainers() {
		return s.ListContainers(ctx)
	}
	return s.accountConfig.GetContainers(), nil
}

// ListBlobs lists all blobs across all storage accounts and their containers
func (c *Client) ListBlobs(ctx context.Context, patterns []string) ([]BlobInfo, error) {
	var allBlobs []BlobInfo

	for _, account := range c.accounts {
		blobs, err := account.ListBlobs(ctx, patterns)
		if err != nil {
			// Log error but continue with other accounts
			fmt.Printf("Warning: failed to list blobs in storage account %s: %v\n", account.accountConfig.Name, err)
			continue
		}
		allBlobs = append(allBlobs, blobs...)
	}

	return allBlobs, nil
}

// ListBlobs lists all blobs in this storage account matching the patterns
func (s *StorageAccountClient) ListBlobs(ctx context.Context, patterns []string) ([]BlobInfo, error) {
	containers, err := s.GetContainersToScan(ctx)
	if err != nil {
		return nil, err
	}

	var allBlobs []BlobInfo
	for _, containerName := range containers {
		blobs, err := s.ListBlobsInContainer(ctx, containerName, patterns)
		if err != nil {
			// Log error but continue with other containers
			fmt.Printf("Warning: failed to list blobs in %s/%s: %v\n", s.accountConfig.Name, containerName, err)
			continue
		}
		allBlobs = append(allBlobs, blobs...)
	}

	return allBlobs, nil
}

// ListBlobsInContainer lists all blobs in a specific container matching the patterns
func (s *StorageAccountClient) ListBlobsInContainer(ctx context.Context, containerName string, patterns []string) ([]BlobInfo, error) {
	var blobs []BlobInfo

	containerClient := s.serviceClient.NewContainerClient(containerName)
	prefix := s.accountConfig.Prefix

	pager := containerClient.NewListBlobsFlatPager(&container.ListBlobsFlatOptions{
		Prefix: &prefix,
	})

	for pager.More() {
		resp, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to list blobs: %w", err)
		}

		for _, blob := range resp.Segment.BlobItems {
			if blob.Name == nil {
				continue
			}

			name := *blob.Name

			// Check if blob matches any of the patterns
			if !matchesPatterns(name, patterns) {
				continue
			}

			info := BlobInfo{
				StorageAccount: s.accountConfig.Name,
				Container:      containerName,
				Path:           name,
				FullPath:       s.accountConfig.Name + "/" + containerName + "/" + name,
			}

			if blob.Properties != nil {
				if blob.Properties.ETag != nil {
					info.ETag = string(*blob.Properties.ETag)
				}
				if blob.Properties.LastModified != nil {
					info.LastModified = *blob.Properties.LastModified
				}
				if blob.Properties.ContentLength != nil {
					info.Size = *blob.Properties.ContentLength
				}
			}

			blobs = append(blobs, info)
		}
	}

	return blobs, nil
}

// matchesPatterns checks if a blob name matches any of the configured patterns
func matchesPatterns(name string, patterns []string) bool {
	if len(patterns) == 0 {
		return true
	}

	// Get just the filename for pattern matching
	filename := filepath.Base(name)

	for _, pattern := range patterns {
		matched, err := filepath.Match(pattern, filename)
		if err == nil && matched {
			return true
		}
	}

	return false
}

// GetBlob downloads a blob and returns its content with metadata
func (c *Client) GetBlob(ctx context.Context, storageAccount, containerName, path string) (*BlobContent, error) {
	accountClient, err := c.getAccountClient(storageAccount)
	if err != nil {
		return nil, err
	}
	return accountClient.GetBlob(ctx, containerName, path)
}

// GetBlob downloads a blob from this storage account
func (s *StorageAccountClient) GetBlob(ctx context.Context, containerName, path string) (*BlobContent, error) {
	containerClient := s.serviceClient.NewContainerClient(containerName)
	blobClient := containerClient.NewBlobClient(path)

	resp, err := blobClient.DownloadStream(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to download blob: %w", err)
	}
	defer resp.Body.Close()

	content, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read blob content: %w", err)
	}

	// Compute content hash
	hash := sha256.Sum256(content)
	contentHash := hex.EncodeToString(hash[:])

	blob := &BlobContent{
		BlobInfo: BlobInfo{
			StorageAccount: s.accountConfig.Name,
			Container:      containerName,
			Path:           path,
			FullPath:       s.accountConfig.Name + "/" + containerName + "/" + path,
		},
		Content:     content,
		ContentHash: contentHash,
	}

	if resp.ETag != nil {
		blob.ETag = string(*resp.ETag)
	}
	if resp.LastModified != nil {
		blob.LastModified = *resp.LastModified
	}
	if resp.ContentLength != nil {
		blob.Size = *resp.ContentLength
	}

	return blob, nil
}

// GetBlobByFullPath downloads a blob using its full path (storageaccount/container/blobpath)
func (c *Client) GetBlobByFullPath(ctx context.Context, fullPath string) (*BlobContent, error) {
	storageAccount, containerName, blobPath, err := ParseFullPath(fullPath)
	if err != nil {
		return nil, err
	}
	return c.GetBlob(ctx, storageAccount, containerName, blobPath)
}

// ParseFullPath parses a full path into storage account, container, and blob path
func ParseFullPath(fullPath string) (storageAccount, container, blobPath string, err error) {
	parts := strings.SplitN(fullPath, "/", 3)
	if len(parts) != 3 {
		return "", "", "", fmt.Errorf("invalid full path: %s (expected storageaccount/container/path)", fullPath)
	}
	return parts[0], parts[1], parts[2], nil
}

// UploadBlob uploads content to a blob
func (c *Client) UploadBlob(ctx context.Context, storageAccount, containerName, path string, content []byte) error {
	accountClient, err := c.getAccountClient(storageAccount)
	if err != nil {
		return err
	}
	return accountClient.UploadBlob(ctx, containerName, path, content)
}

// UploadBlob uploads content to a blob in this storage account
func (s *StorageAccountClient) UploadBlob(ctx context.Context, containerName, path string, content []byte) error {
	containerClient := s.serviceClient.NewContainerClient(containerName)
	blobClient := containerClient.NewBlockBlobClient(path)

	_, err := blobClient.UploadBuffer(ctx, content, nil)
	if err != nil {
		return fmt.Errorf("failed to upload blob: %w", err)
	}

	return nil
}

// UploadBlobByFullPath uploads content using full path (storageaccount/container/blobpath)
func (c *Client) UploadBlobByFullPath(ctx context.Context, fullPath string, content []byte) error {
	storageAccount, containerName, blobPath, err := ParseFullPath(fullPath)
	if err != nil {
		return err
	}
	return c.UploadBlob(ctx, storageAccount, containerName, blobPath, content)
}

// BlobExists checks if a blob exists
func (c *Client) BlobExists(ctx context.Context, storageAccount, containerName, path string) (bool, error) {
	accountClient, err := c.getAccountClient(storageAccount)
	if err != nil {
		return false, err
	}
	return accountClient.BlobExists(ctx, containerName, path)
}

// BlobExists checks if a blob exists in this storage account
func (s *StorageAccountClient) BlobExists(ctx context.Context, containerName, path string) (bool, error) {
	containerClient := s.serviceClient.NewContainerClient(containerName)
	blobClient := containerClient.NewBlobClient(path)

	_, err := blobClient.GetProperties(ctx, nil)
	if err != nil {
		if strings.Contains(err.Error(), "BlobNotFound") || strings.Contains(err.Error(), "404") {
			return false, nil
		}
		return false, fmt.Errorf("failed to check blob existence: %w", err)
	}

	return true, nil
}

// ComputeHash computes the SHA256 hash of content
func ComputeHash(content []byte) string {
	hash := sha256.Sum256(content)
	return hex.EncodeToString(hash[:])
}
