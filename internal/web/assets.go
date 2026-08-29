package web

import (
	"embed"
	"net/http"
)

//go:embed index.html style.css app.js manifest.webmanifest sw.js icon-192.png icon-512.png icon-maskable-512.png
var Assets embed.FS

// Asset represents an embedded web asset.
type Asset struct {
	Content     []byte
	ContentType string
}

var assetMap = map[string]Asset{
	"/":             {ContentType: "text/html; charset=utf-8"},
	"/index.html":   {ContentType: "text/html; charset=utf-8"},
	"/style.css":    {ContentType: "text/css; charset=utf-8"},
	"/app.js":       {ContentType: "application/javascript"},
	"/manifest.webmanifest": {ContentType: "application/manifest+json"},
	"/sw.js":        {ContentType: "application/javascript"},
	"/icon-192.png": {ContentType: "image/png"},
	"/icon-512.png": {ContentType: "image/png"},
	"/icon-maskable-512.png": {ContentType: "image/png"},
}

// Get returns the embedded asset for the given path, or nil if not found.
func Get(path string) *Asset {
	if a, ok := assetMap[path]; ok {
		data, err := Assets.ReadFile(path[1:]) // strip leading /
		if err != nil {
			return nil
		}
		return &Asset{Content: data, ContentType: a.ContentType}
	}
	return nil
}

// ServeStatic serves the static assets via HTTP.
func ServeStatic(w http.ResponseWriter, r *http.Request) {
	asset := Get(r.URL.Path)
	if asset == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", asset.ContentType)
	w.Write(asset.Content)
}