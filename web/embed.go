package web

import (
	"embed"
	"io/fs"
)

//go:embed static/*
var staticFiles embed.FS

// StaticFiles returns the embedded static files filesystem
var StaticFiles fs.FS

func init() {
	var err error
	StaticFiles, err = fs.Sub(staticFiles, "static")
	if err != nil {
		panic(err)
	}
}
