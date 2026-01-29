package store

import (
	"time"
)

// ChangeType represents the type of change detected
type ChangeType string

const (
	ChangeTypeCreated  ChangeType = "created"
	ChangeTypeModified ChangeType = "modified"
	ChangeTypeDeleted  ChangeType = "deleted"
)

// File represents a tracked file in the database
type File struct {
	ID           int64     `json:"id"`
	BlobPath     string    `json:"blob_path"`
	ETag         string    `json:"etag"`
	ContentHash  string    `json:"content_hash"`
	LastModified time.Time `json:"last_modified"`
	IsDeleted    bool      `json:"is_deleted"`
}

// Version represents a historical version of a file
type Version struct {
	ID               int64      `json:"id"`
	FileID           int64      `json:"file_id"`
	Content          string     `json:"content"`
	ContentHash      string     `json:"content_hash"`
	ChangeType       ChangeType `json:"change_type"`
	CapturedAt       time.Time  `json:"captured_at"`
	BlobETag         string     `json:"blob_etag"`
	BlobLastModified time.Time  `json:"blob_last_modified"`
}

// FileWithVersionCount extends File with version count for listing
type FileWithVersionCount struct {
	File
	VersionCount   int       `json:"version_count"`
	LatestChange   time.Time `json:"latest_change"`
	LatestChangeType ChangeType `json:"latest_change_type"`
}

// Store defines the interface for the version store
type Store interface {
	// File operations
	GetFile(blobPath string) (*File, error)
	GetFileByID(id int64) (*File, error)
	ListFiles() ([]FileWithVersionCount, error)
	UpsertFile(file *File) error
	MarkFileDeleted(blobPath string) error

	// Version operations
	CreateVersion(version *Version) error
	GetVersion(id int64) (*Version, error)
	GetVersionsByFileID(fileID int64) ([]Version, error)
	GetVersionsByFilePath(blobPath string) ([]Version, error)
	GetLatestVersion(fileID int64) (*Version, error)

	// Utility
	Close() error
}
