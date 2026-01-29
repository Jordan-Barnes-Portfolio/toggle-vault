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
	Container    string
	Path         string
	FullPath     string // container/path for unique identification
	ETag         string
	LastModified time.Time
	Size         int64
}

// BlobContent represents the content and metadata of a blob
type BlobContent struct {
	BlobInfo
	Content     []byte
	ContentHash string
}

// Client wraps the Azure Blob SDK client
type Client struct {
	serviceClient *service.Client
	credential    azcore.TokenCredential
	config        config.AzureConfig
}

// NewClient creates a new Azure Blob client based on configuration
func NewClient(cfg config.AzureConfig) (*Client, error) {
	var serviceClient *service.Client
	var cred azcore.TokenCredential
	var err error

	serviceURL := fmt.Sprintf("https://%s.blob.core.windows.net/", cfg.StorageAccount)

	switch cfg.GetAuthMethod() {
	case "connection_string":
		serviceClient, err = service.NewClientFromConnectionString(cfg.ConnectionString, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to create client from connection string: %w", err)
		}

	case "sas_token":
		sasURL := serviceURL
		if !strings.HasPrefix(cfg.SASToken, "?") {
			sasURL += "?"
		}
		sasURL += cfg.SASToken
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
		cred, err = azidentity.NewClientSecretCredential(cfg.TenantID, cfg.ClientID, cfg.ClientSecret, nil)
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

	return &Client{
		serviceClient: serviceClient,
		credential:    cred,
		config:        cfg,
	}, nil
}

// ListContainers lists all containers in the storage account
func (c *Client) ListContainers(ctx context.Context) ([]string, error) {
	var containers []string

	pager := c.serviceClient.NewListContainersPager(nil)
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
func (c *Client) GetContainersToScan(ctx context.Context) ([]string, error) {
	if c.config.ShouldScanAllContainers() {
		return c.ListContainers(ctx)
	}
	return c.config.GetContainers(), nil
}

// ListBlobs lists all blobs across configured containers matching the patterns
func (c *Client) ListBlobs(ctx context.Context, patterns []string) ([]BlobInfo, error) {
	containers, err := c.GetContainersToScan(ctx)
	if err != nil {
		return nil, err
	}

	var allBlobs []BlobInfo
	for _, containerName := range containers {
		blobs, err := c.ListBlobsInContainer(ctx, containerName, patterns)
		if err != nil {
			// Log error but continue with other containers
			fmt.Printf("Warning: failed to list blobs in container %s: %v\n", containerName, err)
			continue
		}
		allBlobs = append(allBlobs, blobs...)
	}

	return allBlobs, nil
}

// ListBlobsInContainer lists all blobs in a specific container matching the patterns
func (c *Client) ListBlobsInContainer(ctx context.Context, containerName string, patterns []string) ([]BlobInfo, error) {
	var blobs []BlobInfo

	containerClient := c.serviceClient.NewContainerClient(containerName)
	prefix := c.config.Prefix

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
				Container: containerName,
				Path:      name,
				FullPath:  containerName + "/" + name,
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
func (c *Client) GetBlob(ctx context.Context, containerName, path string) (*BlobContent, error) {
	containerClient := c.serviceClient.NewContainerClient(containerName)
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
			Container: containerName,
			Path:      path,
			FullPath:  containerName + "/" + path,
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

// GetBlobByFullPath downloads a blob using its full path (container/blobpath)
func (c *Client) GetBlobByFullPath(ctx context.Context, fullPath string) (*BlobContent, error) {
	parts := strings.SplitN(fullPath, "/", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid full path: %s (expected container/path)", fullPath)
	}
	return c.GetBlob(ctx, parts[0], parts[1])
}

// UploadBlob uploads content to a blob
func (c *Client) UploadBlob(ctx context.Context, containerName, path string, content []byte) error {
	containerClient := c.serviceClient.NewContainerClient(containerName)
	blobClient := containerClient.NewBlockBlobClient(path)

	_, err := blobClient.UploadBuffer(ctx, content, nil)
	if err != nil {
		return fmt.Errorf("failed to upload blob: %w", err)
	}

	return nil
}

// UploadBlobByFullPath uploads content using full path (container/blobpath)
func (c *Client) UploadBlobByFullPath(ctx context.Context, fullPath string, content []byte) error {
	parts := strings.SplitN(fullPath, "/", 2)
	if len(parts) != 2 {
		return fmt.Errorf("invalid full path: %s (expected container/path)", fullPath)
	}
	return c.UploadBlob(ctx, parts[0], parts[1], content)
}

// BlobExists checks if a blob exists
func (c *Client) BlobExists(ctx context.Context, containerName, path string) (bool, error) {
	containerClient := c.serviceClient.NewContainerClient(containerName)
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
