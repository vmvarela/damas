package main

import (
	"log/slog"
	"os"

	"github.com/vmvarela/damas/internal/cmd"
)

var (
	version = "dev"
	verbose bool
)

func main() {
	rootCmd := cmd.NewRootCmd(version)
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "Enable verbose logging")

	if err := rootCmd.Execute(); err != nil {
		slog.Error("Command failed", "error", err)
		os.Exit(1)
	}
}