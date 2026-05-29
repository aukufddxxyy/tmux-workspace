# AGENTS.md

## Verified Commands

- Run the full check with `make check`; it expands to `ruby test/tms_test.rb`, `ruby -c lib/tms.rb`, and `ruby -c bin/tms`.
- Run the focused test suite directly with `ruby test/tms_test.rb`; there is no Gemfile, gemspec, Bundler setup, CI config, or external test service.
- Use `bin/tms --help` as the safe CLI smoke check. Normal launches may create, attach, switch, or kill tmux sessions, especially with `--recreate`.
- `make install`, `make uninstall`, and `make config` are operational targets. `make config` copies `.tmux-layout.example.yml` to ignored `.tmux-layout.yml` only when the file is missing.
- Do not invent `bundle`, `npm`, `pnpm`, lint, formatter, typecheck, or codegen commands unless a future manifest/config adds them.

## Source Layout

- `bin/tms` is only the executable shim; all behavior lives in `lib/tms.rb` under the `Tms` module.
- `test/tms_test.rb` uses stdlib/default-gem `minitest` and focuses on session naming, YAML parsing, preset selection, CLI option validation, and tmux plan generation without needing a real tmux server.
- Ignore `.omx/`, `.sisyphus/`, `.DS_Store`, `.tmux-layout.yml`, and `.git/` hook samples as local/session artifacts, not source or workflow guidance.

## Domain Rules

- Use `CONTEXT.md` vocabulary exactly: Workspace Session, Session Display Name, Tmux Session Name, Session Recreate, Primary Worktree, Worktree Root, Launch Directory, Pane Command, Layout Preset, Preset Document, Preset Lookup, Preset Selection, Pane Layout, Launch Override.
- Session naming is Git-aware: non-Git directories use the launch directory name; Git-backed sessions are anchored to the Worktree Root, with the Primary Worktree displayed as `main` regardless of actual branch name. The tmux-safe name replaces `:` and whitespace with `_`.
- Preset Lookup order is `--file`, nearest `.tmux-layout.yml` walking up from the Launch Directory, then `~/.config/tmux-scripts/layouts.yml`. If no preset file exists, `tms` creates a single shell pane.
- Preset Selection prefers `default`, then the only preset when unambiguous; multiple non-default presets require `--preset`.
- `--layout` is a Launch Override and reads a raw Pane Layout document; it cannot be combined with `--preset` or `--file`.

## Implementation Gotchas

- Pane Layout `split` values are only `horizontal` and `vertical`; ratios must match pane count and are converted into sequential tmux `-p` percentages in `Tms::TmuxPlan`.
- Pane `cwd` is resolved relative to the inherited Launch Directory. Pane Commands are sent as `cd <cwd> && <command>; exec <shell>` so panes remain interactive after commands finish.
- Runtime paths call external `git` and `tmux`; tests fake Git/tmux or inspect planned tmux steps instead of requiring live services.
