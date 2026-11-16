# AGENTS.md — Mindtalk (personal fork)

## Builds: the tool, never the shell.

- `run_project_script` is the only build path open to an agent, when it is offered: `build`,
  `strings`, `run`, `help`. It runs outside the sandbox and accepts no other argument, so
  nothing else is reachable through it. Never run `make`, `xcodebuild`, `xcodegen`, the app
  binary, its self-test flags, or `open` from `bash`, and do not ask for sandbox access to.
- `run` quits the old instance, opens the one just built, and writes `Mindtalk running, pid <n>`
  to the log. Read that pid: it is the only evidence that the app on screen is your build.
- The self-test flags (`--hotkey-test`, `--tuning-test`, `--transcribe …`) cannot be passed
  through the tool, and neither can `xcodegen`. Ask the user: name the exact command and say
  what you expect to learn. Same when the tool is not offered at all.
- Then iterate: change → run or ask → read the output → change again. Never declare a fix
  working from a compile you did not have, or from a run you did not see.
- Still alone: read, edit, git, and `lens_diagnostics` (source=lsp) for type and lint findings.
  That is a check, not a build, and it is never evidence the app runs.
- When the summary says nothing useful, read the log file it names — the summary keeps
  diagnostics and the verdict, not everything. A log of a few bytes means the command never ran.

## Working rules

- Match this codebase's existing style. Read the neighbours before writing; do not introduce
  conventions it does not observe. Prefer a local pattern over a "correct" foreign one.
- Pre-existing findings outside the task's scope: report, never fix. Do not reformat or tidy
  code you were not asked to touch.
- Navigate with pi-lens, not grep/read sweeps: `project_report` → `module_report` →
  `read_symbol`/`read_enclosing`; `symbol_search` for identifiers;
  `module_report(path, blastRadius: true)` for impact before touching shared code;
  `lsp_navigation` for definitions and references; `ast_grep_search` for structural patterns.
  These are lazy-loaded — activate them first with `pi_lens_activate_tools`. Keep `grep` for
  literal text, which the graph tools do not cover.
- Never call code clean on a labelled result: `unconfirmed`, `partial`, `truncated`, `stale`,
  `cold`, `degraded`, `unavailable` mean incomplete, not clean. Re-run the fuller path first.
- Checker tuning lives in `.pi-lens.json`, not in prose.

## Project facts (so the user's commands make sense)

- XcodeGen: `Mindtalk.xcodeproj/` is generated — never edit it. The change goes in
  `project.yml`; the user regenerates with `xcodegen generate` / `make project`.
  `docs/DEVELOPMENT.md` is the reference for the rest.
- The user's build commands: `make run` (Debug build + launch), `make build CONFIG=Debug|Release`,
  `make clean`. `run` and `build` are what the tool runs; `make clean`, `make project` and
  `make open` are not in it, so those stay the user's. Output lands in
  `build/Build/Products/<Config>/Mindtalk.app`. A first build
  resolves SwiftPM packages (FluidAudio, MCP) and takes
  several minutes — quote that when you ask for a build.
- The app is `LSUIElement`: no Dock icon, the menu bar is the only UI, `pkill -x Mindtalk` to quit.
- There is no test target and no `swift test`. The test surface is the Debug-only self-tests on
  the built binary (`--hotkey-test`, `--record-test`, `--simulate-keys`,
  `--transcribe <file> --model swedish`, …) — ask the user to run the one that matches the change.
- This fork has no updater and no release path: no Sparkle, no `scripts/release.sh`, no DMG and
  no notarization — the upstream project is closed, so this snapshot is what gets built.
  Signing is Manual with `edrta913-local-dev` and no Apple team (set in `project.yml`).
  `make install` is how the user puts a build in `/Applications`.

## Style specifics

- No line-length convention: about a quarter of all lines exceed 80 columns, and files of 1000+
  lines are normal here. Do not reflow long lines, split long files, or add a linter config.
  The yamllint `line-length` rule is disabled on purpose in `.pi-lens.json`.
- UI text: write new strings in **Swedish** in code, then run `run_project_script` `strings`
  (which is `python3 scripts/strings.py`). Never hand-edit `Mindtalk/Resources/Localizable.xcstrings`.
  Missing Swedish makes a Swedish Mac fall back to English — the most common review comment here.
- Every subsystem is documented by its own source map entry in `docs/DEVELOPMENT.md`; trust it
  over your guess about a file's purpose.
