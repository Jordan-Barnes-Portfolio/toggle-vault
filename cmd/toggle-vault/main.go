package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/toggle-vault/internal/api"
	"github.com/toggle-vault/internal/blob"
	"github.com/toggle-vault/internal/config"
	"github.com/toggle-vault/internal/store"
	"github.com/toggle-vault/internal/syncer"
)

func main() {
	configPath := flag.String("config", "config.yaml", "Path to configuration file")
	flag.Parse()

	// Load configuration
	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	log.Printf("Toggle Vault starting...")
	log.Printf("Storage Account: %s, Container: %s", cfg.Azure.StorageAccount, cfg.Azure.Container)

	// Initialize SQLite store
	db, err := store.NewSQLiteStore(cfg.Database.Path)
	if err != nil {
		log.Fatalf("Failed to initialize database: %v", err)
	}
	defer db.Close()

	log.Printf("Database initialized at %s", cfg.Database.Path)

	// Initialize Azure Blob client
	blobClient, err := blob.NewClient(cfg.Azure)
	if err != nil {
		log.Fatalf("Failed to initialize Azure Blob client: %v", err)
	}

	log.Printf("Azure Blob client initialized")

	// Initialize syncer
	syncService := syncer.New(blobClient, db, cfg.Sync)

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start syncer in background
	go syncService.Start(ctx)
	log.Printf("Syncer started with interval %s", cfg.Sync.Interval)

	// Initialize and start API server
	server := api.NewServer(cfg.Server, db, blobClient)

	// Setup graceful shutdown
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		log.Println("Shutdown signal received, stopping services...")
		cancel()

		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("Error during server shutdown: %v", err)
		}
	}()

	addr := fmt.Sprintf("%s:%d", cfg.Server.Host, cfg.Server.Port)
	log.Printf("Starting web server on http://%s", addr)

	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("Server error: %v", err)
	}

	log.Println("Toggle Vault stopped")
}
