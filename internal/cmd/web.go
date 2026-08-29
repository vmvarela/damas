package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/vmvarela/damas/internal/config"
	"github.com/vmvarela/damas/internal/core"
	"github.com/vmvarela/damas/internal/web"
)

func newWebCmd() *cobra.Command {
	var port int
	var rulesFlag string
	var providerFlag string
	var configPath string
	var noBrowser bool

	cmd := &cobra.Command{
		Use:   "web",
		Short: "Start the web server with embedded frontend",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Load config for default rules
			cfg, err := config.Load(configPath)
			if err != nil && !os.IsNotExist(err) {
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

			// Override provider
			if providerFlag != "" {
				if cfg.PlayerWhite.Llm != nil {
					cfg.PlayerWhite.Llm.Provider = providerFlag
				}
				if cfg.PlayerBlack.Llm != nil {
					cfg.PlayerBlack.Llm.Provider = providerFlag
				}
			}

			fmt.Printf("Damas web on http://127.0.0.1:%d — Ctrl-C to exit\n", port)
			return web.RunWithSignals(port, defaultRules, providerFlag, noBrowser)
		},
	}

	cmd.Flags().IntVarP(&port, "port", "p", 8080, "Port to listen on")
	cmd.Flags().StringVar(&rulesFlag, "rules", "", "Rules variant: english|spanish")
	cmd.Flags().StringVar(&providerFlag, "provider", "", "LLM provider override")
	cmd.Flags().StringVar(&configPath, "config", "config.json", "Config file path")
	cmd.Flags().BoolVar(&noBrowser, "no-browser", false, "Don't open browser")

	return cmd
}