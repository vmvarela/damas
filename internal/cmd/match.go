package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/vmvarela/damas/internal/config"
	"github.com/vmvarela/damas/internal/core"
	"github.com/vmvarela/damas/internal/engine"
)

func newMatchCmd() *cobra.Command {
	var rulesFlag string
	var providerFlag string
	var configPath string

	cmd := &cobra.Command{
		Use:   "match",
		Short: "Run a config-driven match",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Load config
			cfg, err := config.Load(configPath)
			if err != nil {
				return fmt.Errorf("failed to load config: %w", err)
			}

			// Override rules from flag
			if rulesFlag != "" {
				switch rulesFlag {
				case "english":
					cfg.Rules = core.English
				case "spanish":
					cfg.Rules = core.Spanish
				default:
					return fmt.Errorf("invalid rules: %s", rulesFlag)
				}
			}

			// Override provider from flag
			if providerFlag != "" {
				if cfg.PlayerWhite.Llm != nil {
					cfg.PlayerWhite.Llm.Provider = providerFlag
				}
				if cfg.PlayerBlack.Llm != nil {
					cfg.PlayerBlack.Llm.Provider = providerFlag
				}
			}

			// Run match
			return runMatch(cfg)
		},
	}

	cmd.Flags().StringVar(&rulesFlag, "rules", "", "Rules variant: english|spanish")
	cmd.Flags().StringVar(&providerFlag, "provider", "", "LLM provider override")
	cmd.Flags().StringVar(&configPath, "config", "config.json", "Config file path")

	return cmd
}

func runMatch(cfg config.Config) error {
	game := core.InitRules(cfg.Rules)
	defer game.Deinit()

	// Print initial board
	printBoard(game.Board)

	for {
		if game.IsGameOver() {
			winner := game.Winner()
if winner != nil {
			fmt.Printf("Game over. Winner: %s\n", colorString(*winner))
		} else {
			fmt.Println("Game over. Draw.")
		}
			return nil
		}

		player := cfg.PlayerWhite
		if game.Turn == core.Black {
			player = cfg.PlayerBlack
		}

		switch {
		case player.Human != nil:
			if err := playHuman(game); err != nil {
				return err
			}
		case player.Minimax != nil:
			playMinimax(game, player.Minimax.TimeLimitMs)
		case player.Llm != nil:
			// TODO: Implement LLM move when LLM package is fully wired
			fmt.Println("LLM player not yet implemented in CLI")
			os.Exit(1)
		}

		printBoard(game.Board)
	}
}

func playHuman(game *core.Game) error {
	var moves core.MoveList
	game.GenerateMoves(&moves)

	fmt.Printf("Your move (%d legal):\n", moves.Len())
	for i, m := range moves.Slice() {
		from := core.SquareToRowCol(m.From)
		to := core.SquareToRowCol(m.To)
		captureStr := ""
		if m.NumCaptured > 0 {
			captureStr = " (capture)"
		}
		fmt.Printf("  %d: %d,%d -> %d,%d%s\n", i+1, from.Row, from.Col, to.Row, to.Col, captureStr)
	}

	var choice int
	for {
		fmt.Print("Enter move number: ")
		_, err := fmt.Scanln(&choice)
		if err != nil {
			fmt.Println("Invalid input. Enter a number.")
			continue
		}
		if choice < 1 || choice > moves.Len() {
			fmt.Printf("Out of range. Enter a number 1-%d.\n", moves.Len())
			continue
		}
		break
	}

	game.ApplyMove(moves.Slice()[choice-1])
	return nil
}

func playMinimax(game *core.Game, timeLimitMs uint32) {
	state := engine.SearchState{
		HalfmoveClock: game.HalfmoveClock,
		History:       game.PositionHistory,
	}
	result := engine.Search(game.Board, game.Turn, timeLimitMs, game.Rules, state)
	from := core.SquareToRowCol(result.Move.From)
	to := core.SquareToRowCol(result.Move.To)
	fmt.Printf("Engine: %d,%d -> %d,%d (score %d, depth %d, %d nodes)\n",
		from.Row, from.Col, to.Row, to.Col, result.Score, result.Depth, result.Nodes)
	game.ApplyMove(result.Move)
}

func printBoard(board core.Board32) {
	ascii := core.BoardToAscii(board)
	fmt.Println("  +----------------+")
	for row := 0; row < 8; row++ {
		line := string(ascii[row*8 : row*8+8])
		fmt.Printf("%d |%s|\n", row, line)
	}
	fmt.Println("  +----------------+")
}

func colorString(c core.Color) string {
	if c == core.White {
		return "white"
	}
	return "black"
}