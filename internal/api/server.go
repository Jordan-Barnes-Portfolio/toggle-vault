package api

import (
	"context"
	"fmt"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
	"github.com/toggle-vault/internal/blob"
	"github.com/toggle-vault/internal/config"
	"github.com/toggle-vault/internal/store"
	"github.com/toggle-vault/web"
)

// Server represents the HTTP server
type Server struct {
	*http.Server
	router     chi.Router
	store      store.Store
	blobClient *blob.Client
}

// NewServer creates a new HTTP server with all routes configured
func NewServer(cfg config.ServerConfig, st store.Store, blobClient *blob.Client) *Server {
	r := chi.NewRouter()

	// Middleware
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins:   []string{"*"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type", "X-Request-ID"},
		ExposedHeaders:   []string{"Link"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

	s := &Server{
		Server: &http.Server{
			Addr:    fmt.Sprintf("%s:%d", cfg.Host, cfg.Port),
			Handler: r,
		},
		router:     r,
		store:      st,
		blobClient: blobClient,
	}

	// Setup routes
	s.setupRoutes()

	return s
}

// setupRoutes configures all API routes
func (s *Server) setupRoutes() {
	// API routes
	s.router.Route("/api", func(r chi.Router) {
		r.Use(middleware.SetHeader("Content-Type", "application/json"))

		// Health check
		r.Get("/health", s.handleHealth)

		// Files
		r.Get("/files", s.handleListFiles)
		r.Get("/files/{path:.*}/versions", s.handleGetVersions)
		r.Get("/files/{path:.*}/versions/{versionID}", s.handleGetVersion)
		r.Get("/files/{path:.*}/diff/{v1}/{v2}", s.handleDiff)
		r.Post("/files/{path:.*}/restore/{versionID}", s.handleRestore)
		r.Get("/files/{path:.*}", s.handleGetFile)
	})

	// Serve static files for web UI
	s.router.Handle("/*", http.FileServer(http.FS(web.StaticFiles)))
}

// Shutdown gracefully shuts down the server
func (s *Server) Shutdown(ctx context.Context) error {
	return s.Server.Shutdown(ctx)
}
