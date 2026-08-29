package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
	"github.com/vmvarela/damas/internal/config"
	"github.com/vmvarela/damas/internal/core"
)

func newTUICmd() *cobra.Command {
	var rulesFlag string
	var providerFlag string
	var configPath string

	cmd := &cobra.Command{
		Use:   "tui",
		Short: "Start the terminal UI",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Load config for default rules
			cfg, err := config.Load(configPath)
			if err != nil && !isNotExist(err) {
				return fmt.Errorf("failed to load config: %w", err)
			}

			defaultRules := cfg.Rules
			if rulesFlag != "" {
				switch rulesFlag {
				case "english":
					defaultRules = core.English
				case "spanish":
					defaultRules = core.Spanish
				default:
					return fmt.Errorf("invalid rules: %s", rulesFlag)
				}
			}

			fmt.Println("TUI not yet fully implemented")
			fmt.Printf("Would start TUI with rules: %v\n", defaultRules)
			return nil
		},
	}

	cmd.Flags().StringVar(&rulesFlag, "rules", "", "Rules variant: english|spanish")
	cmd.Flags().StringVar(&providerFlag, "provider", "", "LLM provider override")
	cmd.Flags().StringVar(&configPath, "config", "config.json", "Config file path")

	return cmd
}

func isNotExist(err error) bool {
	return err != nil && (err.Error() == "config file not found" || err.Error() == "open config.json: no such file or directory")
}