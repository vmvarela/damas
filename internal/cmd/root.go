package cmd

import (
	"github.com/spf13/cobra"
)

func NewRootCmd(version string) *cobra.Command {
	rootCmd := &cobra.Command{
		Use:     "damas",
		Short:   "Damas (Spanish Checkers) engine",
		Version: version,
		Run: func(cmd *cobra.Command, args []string) {
			// Default to match command
			_ = cmd.Help()
		},
	}

	rootCmd.AddCommand(newMatchCmd())
	rootCmd.AddCommand(newWebCmd())
	rootCmd.AddCommand(newTUICmd())
	rootCmd.AddCommand(newWASMCmd())

	return rootCmd
}