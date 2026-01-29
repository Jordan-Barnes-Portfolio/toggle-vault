package store

import (
	"database/sql"
	"fmt"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

// SQLiteStore implements the Store interface using SQLite
type SQLiteStore struct {
	db *sql.DB
}

// NewSQLiteStore creates a new SQLite store and initializes the schema
func NewSQLiteStore(dbPath string) (*SQLiteStore, error) {
	db, err := sql.Open("sqlite3", dbPath+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}

	store := &SQLiteStore{db: db}
	if err := store.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}

	return store, nil
}

// migrate creates the database schema if it doesn't exist
func (s *SQLiteStore) migrate() error {
	schema := `
	CREATE TABLE IF NOT EXISTS files (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		blob_path TEXT UNIQUE NOT NULL,
		etag TEXT,
		content_hash TEXT,
		last_modified DATETIME,
		is_deleted BOOLEAN DEFAULT FALSE
	);

	CREATE TABLE IF NOT EXISTS versions (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		file_id INTEGER NOT NULL REFERENCES files(id),
		content TEXT NOT NULL,
		content_hash TEXT NOT NULL,
		change_type TEXT NOT NULL,
		captured_at DATETIME DEFAULT CURRENT_TIMESTAMP,
		blob_etag TEXT,
		blob_last_modified DATETIME
	);

	CREATE INDEX IF NOT EXISTS idx_versions_file_id ON versions(file_id);
	CREATE INDEX IF NOT EXISTS idx_versions_captured_at ON versions(captured_at);
	CREATE INDEX IF NOT EXISTS idx_files_blob_path ON files(blob_path);
	`

	_, err := s.db.Exec(schema)
	return err
}

// Close closes the database connection
func (s *SQLiteStore) Close() error {
	return s.db.Close()
}

// GetFile retrieves a file by its blob path
func (s *SQLiteStore) GetFile(blobPath string) (*File, error) {
	var f File
	var lastModified sql.NullString

	err := s.db.QueryRow(`
		SELECT id, blob_path, etag, content_hash, last_modified, is_deleted
		FROM files WHERE blob_path = ?
	`, blobPath).Scan(&f.ID, &f.BlobPath, &f.ETag, &f.ContentHash, &lastModified, &f.IsDeleted)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get file: %w", err)
	}

	if lastModified.Valid {
		f.LastModified = parseTime(lastModified.String)
	}

	return &f, nil
}

// GetFileByID retrieves a file by its ID
func (s *SQLiteStore) GetFileByID(id int64) (*File, error) {
	var f File
	var lastModified sql.NullString

	err := s.db.QueryRow(`
		SELECT id, blob_path, etag, content_hash, last_modified, is_deleted
		FROM files WHERE id = ?
	`, id).Scan(&f.ID, &f.BlobPath, &f.ETag, &f.ContentHash, &lastModified, &f.IsDeleted)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get file: %w", err)
	}

	if lastModified.Valid {
		f.LastModified = parseTime(lastModified.String)
	}

	return &f, nil
}

// ListFiles returns all tracked files with version counts
func (s *SQLiteStore) ListFiles() ([]FileWithVersionCount, error) {
	rows, err := s.db.Query(`
		SELECT 
			f.id, f.blob_path, f.etag, f.content_hash, f.last_modified, f.is_deleted,
			COUNT(v.id) as version_count,
			COALESCE(MAX(v.captured_at), f.last_modified) as latest_change,
			(SELECT change_type FROM versions WHERE file_id = f.id ORDER BY captured_at DESC LIMIT 1) as latest_change_type
		FROM files f
		LEFT JOIN versions v ON f.id = v.file_id
		GROUP BY f.id
		ORDER BY f.blob_path
	`)
	if err != nil {
		return nil, fmt.Errorf("failed to list files: %w", err)
	}
	defer rows.Close()

	var files []FileWithVersionCount
	for rows.Next() {
		var f FileWithVersionCount
		var lastModified, latestChange sql.NullString
		var latestChangeType sql.NullString

		err := rows.Scan(
			&f.ID, &f.BlobPath, &f.ETag, &f.ContentHash, &lastModified, &f.IsDeleted,
			&f.VersionCount, &latestChange, &latestChangeType,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan file row: %w", err)
		}

		if lastModified.Valid {
			f.LastModified = parseTime(lastModified.String)
		}
		if latestChange.Valid {
			f.LatestChange = parseTime(latestChange.String)
		}
		if latestChangeType.Valid {
			f.LatestChangeType = ChangeType(latestChangeType.String)
		}

		files = append(files, f)
	}

	return files, rows.Err()
}

// UpsertFile creates or updates a file record
func (s *SQLiteStore) UpsertFile(file *File) error {
	result, err := s.db.Exec(`
		INSERT INTO files (blob_path, etag, content_hash, last_modified, is_deleted)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(blob_path) DO UPDATE SET
			etag = excluded.etag,
			content_hash = excluded.content_hash,
			last_modified = excluded.last_modified,
			is_deleted = excluded.is_deleted
	`, file.BlobPath, file.ETag, file.ContentHash, file.LastModified, file.IsDeleted)
	if err != nil {
		return fmt.Errorf("failed to upsert file: %w", err)
	}

	// Get the ID if it was an insert
	if file.ID == 0 {
		id, err := result.LastInsertId()
		if err == nil && id > 0 {
			file.ID = id
		} else {
			// It was an update, get the existing ID
			existing, err := s.GetFile(file.BlobPath)
			if err == nil && existing != nil {
				file.ID = existing.ID
			}
		}
	}

	return nil
}

// MarkFileDeleted marks a file as deleted
func (s *SQLiteStore) MarkFileDeleted(blobPath string) error {
	_, err := s.db.Exec(`
		UPDATE files SET is_deleted = TRUE WHERE blob_path = ?
	`, blobPath)
	return err
}

// CreateVersion creates a new version record
func (s *SQLiteStore) CreateVersion(version *Version) error {
	result, err := s.db.Exec(`
		INSERT INTO versions (file_id, content, content_hash, change_type, captured_at, blob_etag, blob_last_modified)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, version.FileID, version.Content, version.ContentHash, version.ChangeType, version.CapturedAt, version.BlobETag, version.BlobLastModified)
	if err != nil {
		return fmt.Errorf("failed to create version: %w", err)
	}

	id, err := result.LastInsertId()
	if err == nil {
		version.ID = id
	}

	return nil
}

// GetVersion retrieves a specific version by ID
func (s *SQLiteStore) GetVersion(id int64) (*Version, error) {
	var v Version
	var capturedAt, blobLastModified sql.NullString

	err := s.db.QueryRow(`
		SELECT id, file_id, content, content_hash, change_type, captured_at, blob_etag, blob_last_modified
		FROM versions WHERE id = ?
	`, id).Scan(&v.ID, &v.FileID, &v.Content, &v.ContentHash, &v.ChangeType, &capturedAt, &v.BlobETag, &blobLastModified)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get version: %w", err)
	}

	if capturedAt.Valid {
		v.CapturedAt = parseTime(capturedAt.String)
	}
	if blobLastModified.Valid {
		v.BlobLastModified = parseTime(blobLastModified.String)
	}

	return &v, nil
}

// GetVersionsByFileID retrieves all versions for a file by file ID
func (s *SQLiteStore) GetVersionsByFileID(fileID int64) ([]Version, error) {
	rows, err := s.db.Query(`
		SELECT id, file_id, content, content_hash, change_type, captured_at, blob_etag, blob_last_modified
		FROM versions WHERE file_id = ?
		ORDER BY captured_at DESC
	`, fileID)
	if err != nil {
		return nil, fmt.Errorf("failed to get versions: %w", err)
	}
	defer rows.Close()

	return scanVersions(rows)
}

// GetVersionsByFilePath retrieves all versions for a file by blob path
func (s *SQLiteStore) GetVersionsByFilePath(blobPath string) ([]Version, error) {
	rows, err := s.db.Query(`
		SELECT v.id, v.file_id, v.content, v.content_hash, v.change_type, v.captured_at, v.blob_etag, v.blob_last_modified
		FROM versions v
		JOIN files f ON v.file_id = f.id
		WHERE f.blob_path = ?
		ORDER BY v.captured_at DESC
	`, blobPath)
	if err != nil {
		return nil, fmt.Errorf("failed to get versions: %w", err)
	}
	defer rows.Close()

	return scanVersions(rows)
}

// GetLatestVersion retrieves the most recent version for a file
func (s *SQLiteStore) GetLatestVersion(fileID int64) (*Version, error) {
	var v Version
	var capturedAt, blobLastModified sql.NullString

	err := s.db.QueryRow(`
		SELECT id, file_id, content, content_hash, change_type, captured_at, blob_etag, blob_last_modified
		FROM versions WHERE file_id = ?
		ORDER BY captured_at DESC LIMIT 1
	`, fileID).Scan(&v.ID, &v.FileID, &v.Content, &v.ContentHash, &v.ChangeType, &capturedAt, &v.BlobETag, &blobLastModified)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("failed to get latest version: %w", err)
	}

	if capturedAt.Valid {
		v.CapturedAt = parseTime(capturedAt.String)
	}
	if blobLastModified.Valid {
		v.BlobLastModified = parseTime(blobLastModified.String)
	}

	return &v, nil
}

// scanVersions is a helper to scan multiple version rows
func scanVersions(rows *sql.Rows) ([]Version, error) {
	var versions []Version
	for rows.Next() {
		var v Version
		var capturedAt, blobLastModified sql.NullString

		err := rows.Scan(&v.ID, &v.FileID, &v.Content, &v.ContentHash, &v.ChangeType, &capturedAt, &v.BlobETag, &blobLastModified)
		if err != nil {
			return nil, fmt.Errorf("failed to scan version row: %w", err)
		}

		if capturedAt.Valid {
			v.CapturedAt = parseTime(capturedAt.String)
		}
		if blobLastModified.Valid {
			v.BlobLastModified = parseTime(blobLastModified.String)
		}

		versions = append(versions, v)
	}

	return versions, rows.Err()
}

// parseTime parses a SQLite datetime string into time.Time
func parseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	
	// Try various SQLite datetime formats
	formats := []string{
		"2006-01-02 15:04:05",
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05.000Z",
		time.RFC3339,
		time.RFC3339Nano,
	}
	
	for _, format := range formats {
		if t, err := time.Parse(format, s); err == nil {
			return t
		}
	}
	
	return time.Time{}
}
