package syncer

import (
	"context"
	"log"
	"time"

	"github.com/toggle-vault/internal/blob"
	"github.com/toggle-vault/internal/config"
	"github.com/toggle-vault/internal/store"
)

// Syncer periodically checks for blob changes and records versions
type Syncer struct {
	blobClient *blob.Client
	store      store.Store
	config     config.SyncConfig
}

// New creates a new Syncer instance
func New(blobClient *blob.Client, store store.Store, cfg config.SyncConfig) *Syncer {
	return &Syncer{
		blobClient: blobClient,
		store:      store,
		config:     cfg,
	}
}

// Start begins the sync loop
func (s *Syncer) Start(ctx context.Context) {
	// Run initial sync immediately
	s.sync(ctx)

	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("Syncer stopping...")
			return
		case <-ticker.C:
			s.sync(ctx)
		}
	}
}

// sync performs a single sync cycle
func (s *Syncer) sync(ctx context.Context) {
	log.Println("Starting sync cycle...")

	// List all blobs matching our patterns
	blobs, err := s.blobClient.ListBlobs(ctx, s.config.Patterns)
	if err != nil {
		log.Printf("Error listing blobs: %v", err)
		return
	}

	log.Printf("Found %d blobs matching patterns", len(blobs))

	// Track which blob paths we've seen (for detecting deletions)
	// Use FullPath (container/path) for unique identification
	seenPaths := make(map[string]bool)

	// Process each blob
	for _, blobInfo := range blobs {
		seenPaths[blobInfo.FullPath] = true

		if err := s.processBlob(ctx, blobInfo); err != nil {
			log.Printf("Error processing blob %s: %v", blobInfo.FullPath, err)
		}
	}

	// Check for deleted files
	if err := s.checkDeleted(ctx, seenPaths); err != nil {
		log.Printf("Error checking for deleted files: %v", err)
	}

	log.Println("Sync cycle complete")
}

// processBlob handles a single blob, detecting if it's new or modified
func (s *Syncer) processBlob(ctx context.Context, blobInfo blob.BlobInfo) error {
	// Check if we already have this file in the database (using FullPath)
	existingFile, err := s.store.GetFile(blobInfo.FullPath)
	if err != nil {
		return err
	}

	// New file
	if existingFile == nil {
		return s.handleNewFile(ctx, blobInfo)
	}

	// File was previously deleted but now exists again
	if existingFile.IsDeleted {
		log.Printf("File %s was deleted but now exists again", blobInfo.FullPath)
		return s.handleNewFile(ctx, blobInfo)
	}

	// Check if ETag changed (quick check before downloading)
	if existingFile.ETag == blobInfo.ETag {
		// No change
		return nil
	}

	// ETag changed, need to download and check content
	return s.handleModifiedFile(ctx, blobInfo, existingFile)
}

// handleNewFile processes a newly discovered file
func (s *Syncer) handleNewFile(ctx context.Context, blobInfo blob.BlobInfo) error {
	log.Printf("New file detected: %s", blobInfo.FullPath)

	// Download the content
	blobContent, err := s.blobClient.GetBlob(ctx, blobInfo.Container, blobInfo.Path)
	if err != nil {
		return err
	}

	// Create the file record using FullPath for unique identification
	file := &store.File{
		BlobPath:     blobInfo.FullPath,
		ETag:         blobContent.ETag,
		ContentHash:  blobContent.ContentHash,
		LastModified: blobContent.LastModified,
		IsDeleted:    false,
	}

	if err := s.store.UpsertFile(file); err != nil {
		return err
	}

	// Create the initial version
	version := &store.Version{
		FileID:           file.ID,
		Content:          string(blobContent.Content),
		ContentHash:      blobContent.ContentHash,
		ChangeType:       store.ChangeTypeCreated,
		CapturedAt:       time.Now(),
		BlobETag:         blobContent.ETag,
		BlobLastModified: blobContent.LastModified,
	}

	if err := s.store.CreateVersion(version); err != nil {
		return err
	}

	log.Printf("Recorded new file: %s (version %d)", blobInfo.FullPath, version.ID)
	return nil
}

// handleModifiedFile processes a file that may have been modified
func (s *Syncer) handleModifiedFile(ctx context.Context, blobInfo blob.BlobInfo, existingFile *store.File) error {
	// Download the content to check if it actually changed
	blobContent, err := s.blobClient.GetBlob(ctx, blobInfo.Container, blobInfo.Path)
	if err != nil {
		return err
	}

	// Check if content actually changed (ETag might change without content changing)
	if blobContent.ContentHash == existingFile.ContentHash {
		// Content same, just update ETag
		existingFile.ETag = blobContent.ETag
		existingFile.LastModified = blobContent.LastModified
		return s.store.UpsertFile(existingFile)
	}

	log.Printf("File modified: %s", blobInfo.FullPath)

	// Content changed, record new version
	version := &store.Version{
		FileID:           existingFile.ID,
		Content:          string(blobContent.Content),
		ContentHash:      blobContent.ContentHash,
		ChangeType:       store.ChangeTypeModified,
		CapturedAt:       time.Now(),
		BlobETag:         blobContent.ETag,
		BlobLastModified: blobContent.LastModified,
	}

	if err := s.store.CreateVersion(version); err != nil {
		return err
	}

	// Update file record
	existingFile.ETag = blobContent.ETag
	existingFile.ContentHash = blobContent.ContentHash
	existingFile.LastModified = blobContent.LastModified

	if err := s.store.UpsertFile(existingFile); err != nil {
		return err
	}

	log.Printf("Recorded modified file: %s (version %d)", blobInfo.FullPath, version.ID)
	return nil
}

// checkDeleted looks for files that are in our database but no longer in blob storage
func (s *Syncer) checkDeleted(ctx context.Context, seenPaths map[string]bool) error {
	files, err := s.store.ListFiles()
	if err != nil {
		return err
	}

	for _, file := range files {
		// Skip already deleted files
		if file.IsDeleted {
			continue
		}

		// If we didn't see this path in the current blob listing, it was deleted
		if !seenPaths[file.BlobPath] {
			log.Printf("File deleted: %s", file.BlobPath)

			// Get the last version to record in the delete version
			lastVersion, err := s.store.GetLatestVersion(file.ID)
			if err != nil {
				log.Printf("Error getting latest version for deleted file %s: %v", file.BlobPath, err)
				continue
			}

			// Record deletion version
			version := &store.Version{
				FileID:      file.ID,
				Content:     "", // Empty content for deleted files
				ContentHash: "",
				ChangeType:  store.ChangeTypeDeleted,
				CapturedAt:  time.Now(),
			}

			// Preserve the last known content hash
			if lastVersion != nil {
				version.ContentHash = lastVersion.ContentHash
			}

			if err := s.store.CreateVersion(version); err != nil {
				log.Printf("Error creating delete version for %s: %v", file.BlobPath, err)
				continue
			}

			// Mark file as deleted
			if err := s.store.MarkFileDeleted(file.BlobPath); err != nil {
				log.Printf("Error marking file as deleted %s: %v", file.BlobPath, err)
			}

			log.Printf("Recorded deleted file: %s (version %d)", file.BlobPath, version.ID)
		}
	}

	return nil
}

// SyncNow triggers an immediate sync (useful for testing or manual refresh)
func (s *Syncer) SyncNow(ctx context.Context) {
	s.sync(ctx)
}
