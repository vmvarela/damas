package web

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/gorilla/websocket"
	"github.com/vmvarela/damas/internal/core"
	"github.com/vmvarela/damas/internal/protocol"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// Server holds the web server state.
type Server struct {
	Port         int
	DefaultRules core.Variant
	Provider     string
	connState    *protocol.ConnState
}

// NewServer creates a new web server.
func NewServer(port int, defaultRules core.Variant, provider string) *Server {
	return &Server{
		Port:         port,
		DefaultRules: defaultRules,
		Provider:     provider,
		connState: &protocol.ConnState{
			BuildProvider: func() interface{} {
				if provider == "" {
					return nil
				}
				// In a real implementation, this would create an LLM provider
				// For now, return nil to indicate LLM unavailable
				return nil
			},
		},
	}
}

// Run starts the HTTP server.
func (s *Server) Run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", ServeStatic)
	mux.HandleFunc("/ws", s.handleWebSocket)

	server := &http.Server{
		Addr:    ":" + strconv.Itoa(s.Port),
		Handler: mux,
	}

	go func() {
		<-ctx.Done()
		server.Shutdown(context.Background())
	}()

	slog.Info("Web server starting", "port", s.Port)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}

func (s *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		slog.Error("WebSocket upgrade failed", "error", err)
		return
	}
	defer conn.Close()

	game := core.InitRules(s.DefaultRules)
	defer game.Deinit()

	connState := &protocol.ConnState{
		BuildProvider: s.connState.BuildProvider,
	}

	for {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			slog.Error("WebSocket read error", "error", err)
			break
		}

		resp := protocol.HandleMessage(game, connState, msg, s.DefaultRules)
		if err := conn.WriteMessage(websocket.TextMessage, resp); err != nil {
			slog.Error("WebSocket write error", "error", err)
			break
		}
	}
}

// RunWithSignals runs the server and handles OS signals.
func RunWithSignals(port int, defaultRules core.Variant, provider string, noBrowser bool) error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	s := NewServer(port, defaultRules, provider)

	if !noBrowser {
		go openBrowser(port)
	}

	return s.Run(ctx)
}

func openBrowser(port int) {
	url := "http://127.0.0.1:" + strconv.Itoa(port)
	var cmd string
	switch os.Getenv("GOOS") {
	case "darwin":
		cmd = "open"
	case "linux":
		cmd = "xdg-open"
	default:
		return
	}
	// Note: In production, use exec.CommandContext
	_ = cmd
	_ = url
}