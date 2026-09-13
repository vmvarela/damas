damas(1)

NAME
	damas - checkers game: CLI, TUI and embedded web server in one binary

SYNOPSIS
	*damas* [_options_]
	*damas* [_command_] [_options_]

DESCRIPTION
	*damas* is a single binary that bundles a checkers engine with three
	interfaces: a config-driven match CLI, an interactive terminal UI, and
	a web server with an embedded browser frontend.

	Running *damas* with no command starts a match described by
	*config.json* in the current working directory: two players (white and
	black), each one human, a minimax engine, or an LLM. See
	CONFIGURATION.

COMMANDS
	*web*
		Start the web server on 127.0.0.1 and open the default browser.
		The frontend is embedded in the binary; games are played over a
		WebSocket.

	*tui*
		Interactive terminal UI.

	*help*, *-h*, *--help*
		Print the usage summary.

	Any other command argument prints the usage summary and exits with
	status 1.

OPTIONS
	Options are accepted before or after the subcommand.

	*--rules* _english_|_spanish_
		Rules variant. Parsed strictly: any other value is an error
		(usage + exit 1). Defaults to the *rules* field in config.json
		(*spanish* if absent); in web mode it sets the default variant
		for new games (the web selector can override it).

	*--provider* _name_
		LLM provider name (OpenAI-compatible). Overrides the provider
		in config.json and environment auto-detection.

	*--version*
		Print the version and exit.

	Unknown flags (any argument starting with *--* other than the above)
	print the usage summary and exit with status 1.

CONFIGURATION
	*config.json* in the current working directory drives the match CLI.
	Required for bare *damas*; a missing file is an error (exit 1).

	{
		"rules": "english" | "spanish",
		"player_white": { ... },
		"player_black": { ... }
	}

	*rules* is optional (default *spanish*; unknown values fall back to
	*spanish*). Each player object is one of:

	- *{"type": "human"}* — interactive move choice from stdin (CLI only).
	- *{"type": "minimax", "time_limit_ms": <ms>}* — built-in engine with a per-move time limit in milliseconds.
	- *{"type": "llm", "provider": "<name>", "model": "<model>"}* — LLM player. *provider* is optional (see ENVIRONMENT); *model* is required. The web frontend defaults to *llama-3.3-70b-versatile* when no model is specified.

ENVIRONMENT
	*API keys*
		Each OpenAI-compatible provider reads its key from one
		environment variable: *GROQ_API_KEY*, *OPENAI_API_KEY*,
		*DEEPSEEK_API_KEY*, *MISTRAL_API_KEY*, *TOGETHER_API_KEY*,
		*FIREWORKS_API_KEY*, *XAI_API_KEY*, *CEREBRAS_API_KEY*,
		*OPENROUTER_API_KEY*, *PERPLEXITY_API_KEY*,
		*SAMBANOVA_API_KEY*, *DEEPINFRA_API_KEY*, *GITHUB_TOKEN*
		(provider *github*). With no *--provider* flag and no provider
		in config.json, the first set variable in that order is used.
		*ollama* needs no key (it talks to *http://localhost:11434*).

	*DZ_WS_PORT*
		Port for *damas* web. Default *8080*; invalid values also fall
		back to *8080*.

	*DZ_NO_BROWSER*
		When set (e.g. to *1*), *damas web* does not launch a browser.

EXIT STATUS
	*0*
		Success.

	*1*
		Error: unknown flag or subcommand, missing or invalid
		config.json, missing API key, web port bind failure, or LLM
		request failure.

EXAMPLES
	Run the match described by config.json:

		damas

	Force the english rules variant:

		damas --rules english

	Serve the web UI on port 9000 without opening a browser:

		DZ_WS_PORT=9000 DZ_NO_BROWSER=1 damas web

	Open the terminal UI:

		damas tui

AUTHORS
	Maintained by vmvarela <vmvarela@gmail.com>.

SEE ALSO
	Project repository: https://github.com/vmvarela/damas
