package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config represents the application configuration
type Config struct {
	Azure    AzureConfig    `yaml:"azure"`
	Sync     SyncConfig     `yaml:"sync"`
	Database DatabaseConfig `yaml:"database"`
	Server   ServerConfig   `yaml:"server"`
}

// AzureConfig contains Azure Blob Storage settings
type AzureConfig struct {
	StorageAccount   string `yaml:"storage_account"`
	ConnectionString string `yaml:"connection_string"`
	SASToken         string `yaml:"sas_token"`
	Prefix           string `yaml:"prefix"`
	// For service principal auth
	TenantID     string `yaml:"tenant_id"`
	ClientID     string `yaml:"client_id"`
	ClientSecret string `yaml:"client_secret"`
	// Use managed identity
	UseManagedIdentity bool `yaml:"use_managed_identity"`

	// Container scoping options:
	// - If ScanAllContainers is true, all containers in the storage account are scanned
	// - If Containers is specified, only those containers are scanned
	// - If Container (singular) is specified, only that container is scanned (backward compatible)
	ScanAllContainers bool     `yaml:"scan_all_containers"`
	Containers        []string `yaml:"containers"`
	Container         string   `yaml:"container"` // Backward compatible single container
}

// SyncConfig contains sync settings
type SyncConfig struct {
	Interval time.Duration `yaml:"interval"`
	Patterns []string      `yaml:"patterns"`
}

// DatabaseConfig contains database settings
type DatabaseConfig struct {
	Path string `yaml:"path"`
}

// ServerConfig contains HTTP server settings
type ServerConfig struct {
	Port int    `yaml:"port"`
	Host string `yaml:"host"`
}

// Load reads and parses the configuration file
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	// Expand environment variables in the config
	expanded := os.ExpandEnv(string(data))

	var cfg Config
	if err := yaml.Unmarshal([]byte(expanded), &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	// Apply defaults
	cfg.applyDefaults()

	// Validate configuration
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	return &cfg, nil
}

// applyDefaults sets default values for unspecified config options
func (c *Config) applyDefaults() {
	if c.Sync.Interval == 0 {
		c.Sync.Interval = 30 * time.Second
	}

	if len(c.Sync.Patterns) == 0 {
		c.Sync.Patterns = []string{"*.yaml", "*.yml"}
	}

	if c.Database.Path == "" {
		c.Database.Path = "./toggle-vault.db"
	}

	if c.Server.Port == 0 {
		c.Server.Port = 8080
	}

	if c.Server.Host == "" {
		c.Server.Host = "0.0.0.0"
	}
}

// validate checks that the configuration is valid
func (c *Config) validate() error {
	if c.Azure.StorageAccount == "" {
		return fmt.Errorf("azure.storage_account is required")
	}

	// Check that at least one container scoping method is configured
	hasContainerScope := c.Azure.ScanAllContainers ||
		len(c.Azure.Containers) > 0 ||
		c.Azure.Container != ""

	if !hasContainerScope {
		return fmt.Errorf("azure container scope is required: set scan_all_containers, containers, or container")
	}

	// Check that at least one auth method is configured
	hasAuth := c.Azure.ConnectionString != "" ||
		c.Azure.SASToken != "" ||
		c.Azure.UseManagedIdentity ||
		(c.Azure.TenantID != "" && c.Azure.ClientID != "" && c.Azure.ClientSecret != "")

	if !hasAuth {
		return fmt.Errorf("no Azure authentication method configured (connection_string, sas_token, managed_identity, or service principal)")
	}

	return nil
}

// GetContainers returns the list of containers to scan
// Returns nil if scan_all_containers is true (meaning scan all)
func (c *AzureConfig) GetContainers() []string {
	if c.ScanAllContainers {
		return nil // nil means scan all containers
	}
	if len(c.Containers) > 0 {
		return c.Containers
	}
	if c.Container != "" {
		return []string{c.Container}
	}
	return nil
}

// ShouldScanAllContainers returns true if all containers should be scanned
func (c *AzureConfig) ShouldScanAllContainers() bool {
	return c.ScanAllContainers
}

// UnmarshalYAML implements custom unmarshaling for SyncConfig to handle duration
func (s *SyncConfig) UnmarshalYAML(unmarshal func(interface{}) error) error {
	type rawSyncConfig struct {
		Interval string   `yaml:"interval"`
		Patterns []string `yaml:"patterns"`
	}

	var raw rawSyncConfig
	if err := unmarshal(&raw); err != nil {
		return err
	}

	if raw.Interval != "" {
		duration, err := time.ParseDuration(raw.Interval)
		if err != nil {
			return fmt.Errorf("invalid sync interval: %w", err)
		}
		s.Interval = duration
	}

	s.Patterns = raw.Patterns
	return nil
}

// GetAuthMethod returns a string describing the configured auth method
func (c *AzureConfig) GetAuthMethod() string {
	if c.ConnectionString != "" {
		return "connection_string"
	}
	if c.SASToken != "" {
		return "sas_token"
	}
	if c.UseManagedIdentity {
		return "managed_identity"
	}
	if c.TenantID != "" && c.ClientID != "" && c.ClientSecret != "" {
		return "service_principal"
	}
	return "none"
}

// GetServiceURL returns the Azure Blob service URL
func (c *AzureConfig) GetServiceURL() string {
	// If connection string contains AccountName, extract it
	if c.ConnectionString != "" && strings.Contains(c.ConnectionString, "AccountName=") {
		return fmt.Sprintf("https://%s.blob.core.windows.net/", c.StorageAccount)
	}
	return fmt.Sprintf("https://%s.blob.core.windows.net/", c.StorageAccount)
}
