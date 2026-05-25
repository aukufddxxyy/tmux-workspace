# tmux Scripts

`tms` starts or re-enters a named tmux workspace session from any directory.

## Usage

```sh
bin/tms
bin/tms --preset dev
bin/tms --file ./layouts.yml --preset dev
bin/tms --layout ./one-off-layout.yml
bin/tms --recreate --preset dev
```

If the target session already exists, `tms` attaches to it. Use `--recreate` to kill and rebuild that session from the selected layout.

When run inside tmux, `tms` switches the current client to the target session. Outside tmux, it attaches normally.

## Preset Lookup

Preset documents are discovered in this order:

1. `--file <path>`
2. The nearest `.tmux-layout.yml` found by walking up from the launch directory
3. `~/.config/tmux-scripts/layouts.yml`

Without `--preset`, `tms` selects `default`, then the only preset if the file has exactly one preset. If no preset file exists, it opens a single shell pane.

## Session Names

Outside Git, the session name comes from the launch directory name.

Inside Git, the name is anchored to the worktree root:

- Primary worktree: `repo_main`
- Linked worktree: `repo_feature-worktree`

The logical separator is `:`, but the tmux-safe session name uses `_`.

## Preset Document

```yaml
presets:
  default:
    layout:
      split: horizontal
      ratio: [30, 70]
      panes:
        - title: editor
          command: nvim
        - split: vertical
          ratio: [60, 40]
          panes:
            - title: server
              command: pnpm dev
            - title: shell
```

`split: horizontal` creates side-by-side panes. `split: vertical` creates stacked panes. `ratio` is optional and must match the number of panes at that split level.

Pane commands run from the launch directory by default. Add `cwd` to a pane to override it, relative to the launch directory:

```yaml
- title: api
  cwd: ./packages/api
  command: pnpm dev
```

When a command exits, the pane remains open as an interactive shell. A pane without `command` opens an interactive shell immediately.

## One-Off Layout

`--layout` reads a raw layout document instead of a preset document:

```yaml
split: horizontal
panes:
  - command: nvim
  - title: shell
```

## Install

Put `bin/tms` on your `PATH` with the Makefile:

```sh
make install
```

By default this links `bin/tms` to `~/.local/bin/tms`. Override the destination when needed:

```sh
make install BINDIR=/usr/local/bin
```

Create a starter global layout:

```sh
make config
```

`make config` creates `~/.config/tmux-scripts/layouts.yml` from `.tmux-layout.example.yml` only when the file is missing; it will not overwrite an existing layout.

To create a project-local override instead, pass `CONFIG` explicitly:

```sh
make config CONFIG=.tmux-layout.yml
```
