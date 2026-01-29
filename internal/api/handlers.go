package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"

	"github.com/go-chi/chi/v5"
	"github.com/toggle-vault/internal/diff"
	"github.com/toggle-vault/internal/store"
)

// getPathParam extracts and URL-decodes a path parameter from the request
func getPathParam(r *http.Request, name string) string {
	raw := chi.URLParam(r, name)
	if raw == "" {
		return ""
	}
	decoded, err := url.PathUnescape(raw)
	if err != nil {
		return raw // return original if decode fails
	}
	return decoded
}

// APIError represents an error response
type APIError struct {
	Error   string `json:"error"`
	Message string `json:"message,omitempty"`
}

// respondJSON writes a JSON response
func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.WriteHeader(status)
	if data != nil {
		if err := json.NewEncoder(w).Encode(data); err != nil {
			log.Printf("Error encoding JSON response: %v", err)
		}
	}
}

// respondError writes an error response
func respondError(w http.ResponseWriter, status int, message string) {
	respondJSON(w, status, APIError{Error: http.StatusText(status), Message: message})
}

// handleHealth returns the health status of the service
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	respondJSON(w, http.StatusOK, map[string]string{
		"status": "healthy",
	})
}

// handleListFiles returns all tracked files
func (s *Server) handleListFiles(w http.ResponseWriter, r *http.Request) {
	files, err := s.store.ListFiles()
	if err != nil {
		log.Printf("Error listing files: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to list files")
		return
	}

	if files == nil {
		files = []store.FileWithVersionCount{}
	}

	respondJSON(w, http.StatusOK, files)
}

// handleGetFile returns information about a specific file
func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	path := getPathParam(r, "path")
	if path == "" {
		respondError(w, http.StatusBadRequest, "Path is required")
		return
	}

	file, err := s.store.GetFile(path)
	if err != nil {
		log.Printf("Error getting file: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to get file")
		return
	}

	if file == nil {
		respondError(w, http.StatusNotFound, "File not found")
		return
	}

	respondJSON(w, http.StatusOK, file)
}

// handleGetVersions returns all versions for a file
func (s *Server) handleGetVersions(w http.ResponseWriter, r *http.Request) {
	path := getPathParam(r, "path")
	if path == "" {
		respondError(w, http.StatusBadRequest, "Path is required")
		return
	}

	versions, err := s.store.GetVersionsByFilePath(path)
	if err != nil {
		log.Printf("Error getting versions: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to get versions")
		return
	}

	if versions == nil {
		versions = []store.Version{}
	}

	respondJSON(w, http.StatusOK, versions)
}

// handleGetVersion returns a specific version
func (s *Server) handleGetVersion(w http.ResponseWriter, r *http.Request) {
	versionIDStr := chi.URLParam(r, "versionID")
	versionID, err := strconv.ParseInt(versionIDStr, 10, 64)
	if err != nil {
		respondError(w, http.StatusBadRequest, "Invalid version ID")
		return
	}

	version, err := s.store.GetVersion(versionID)
	if err != nil {
		log.Printf("Error getting version: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to get version")
		return
	}

	if version == nil {
		respondError(w, http.StatusNotFound, "Version not found")
		return
	}

	respondJSON(w, http.StatusOK, version)
}

// handleDiff returns a diff between two versions
func (s *Server) handleDiff(w http.ResponseWriter, r *http.Request) {
	path := getPathParam(r, "path")
	v1Str := chi.URLParam(r, "v1")
	v2Str := chi.URLParam(r, "v2")

	v1, err := strconv.ParseInt(v1Str, 10, 64)
	if err != nil {
		respondError(w, http.StatusBadRequest, "Invalid version ID v1")
		return
	}

	v2, err := strconv.ParseInt(v2Str, 10, 64)
	if err != nil {
		respondError(w, http.StatusBadRequest, "Invalid version ID v2")
		return
	}

	// Get both versions
	version1, err := s.store.GetVersion(v1)
	if err != nil {
		log.Printf("Error getting version v1: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to get version")
		return
	}
	if version1 == nil {
		respondError(w, http.StatusNotFound, "Version v1 not found")
		return
	}

	version2, err := s.store.GetVersion(v2)
	if err != nil {
		log.Printf("Error getting version v2: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to get version")
		return
	}
	if version2 == nil {
		respondError(w, http.StatusNotFound, "Version v2 not found")
		return
	}

	// Generate diff
	diffResult := diff.CompareVersions(
		version1.Content,
		version2.Content,
		fmt.Sprintf("%s (v%d)", path, v1),
		fmt.Sprintf("%s (v%d)", path, v2),
	)

	respondJSON(w, http.StatusOK, diffResult)
}

// handleRestore restores a previous version to blob storage
func (s *Server) handleRestore(w http.ResponseWriter, r *http.Request) {
	path := getPathParam(r, "path")
	versionIDStr := chi.URLParam(r, "versionID")

	if path == "" {
		respondError(w, http.StatusBadRequest, "Path is required")
		return
	}

	versionID, err := strconv.ParseInt(versionIDStr, 10, 64)
	if err != nil {
		respondError(w, http.StatusBadRequest, "Invalid version ID")
		return
	}

	// Get the version to restore
	version, err := s.store.GetVersion(versionID)
	if err != nil {
		log.Printf("Error getting version: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to get version")
		return
	}

	if version == nil {
		respondError(w, http.StatusNotFound, "Version not found")
		return
	}

	// Upload the content back to blob storage
	// Path is in format "container/blobpath"
	if err := s.blobClient.UploadBlobByFullPath(r.Context(), path, []byte(version.Content)); err != nil {
		log.Printf("Error restoring blob: %v", err)
		respondError(w, http.StatusInternalServerError, "Failed to restore file")
		return
	}

	log.Printf("Restored %s to version %d", path, versionID)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Restored %s to version %d", path, versionID),
		"path":    path,
		"version": versionID,
	})
}
