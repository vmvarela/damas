package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

func newWASMCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "wasm",
		Short: "Build the WASM binary",
		RunE: func(cmd *cobra.Command, args []string) error {
			fmt.Println("Building WASM binary...")
			fmt.Println("Run: GOOS=js GOARCH=wasm go build -o web/damas.wasm ./cmd/wasm")
			return nil
		},
	}

	return cmd
}