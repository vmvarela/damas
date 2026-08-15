# AGENTS.md

- Use Zig 0.16.0 for all backend and core code, except in environments where Zig is not applicable (e.g., web frontends or mobile/desktop apps built with other toolchains).
- Write the test before implementing a feature. Tests come first.
- Run the full test suite before every commit, and ensure all tests pass. Do not commit with failing tests.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages.
- Write all documentation and code comments in English.