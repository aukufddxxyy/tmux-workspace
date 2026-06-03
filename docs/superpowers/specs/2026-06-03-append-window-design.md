# Append Window Command Design

Date: 2026-06-03

## Summary

Add `-A, --append-window` to `tms`. The option appends a new tmux window to the target Workspace Session resolved from the Launch Directory. The new window uses the same Layout Preset / Launch Override selection rules that `tms` already uses for creating a Workspace Session.

This is a launch-mode change, not a new multi-window preset system. A Pane Layout remains a single-window split structure.

## Goals

- Let users add another window to the target Workspace Session without manually running tmux commands.
- Reuse existing `--preset`, `--file`, `--layout`, Preset Lookup, and Preset Selection behavior.
- Preserve current default behavior for commands that do not pass `--append-window`.
- Keep implementation bounded and testable without introducing multi-window Layout Presets.

## Non-Goals

- Do not add multi-window preset documents.
- Do not add legacy compatibility paths or migration behavior as part of this feature.
- Do not prevent duplicate tmux window names; tmux allows them.
- Do not change Pane Layout semantics beyond selecting which tmux window receives the layout.

## User-Facing Behavior

### New option

```sh
tms -A
tms --append-window
```

Help output should include:

```text
-A, --append-window            Append a window to the workspace session
```

### Normal mode stays unchanged

Without `--append-window`, existing behavior remains:

- If the target Workspace Session exists, attach or switch to it immediately.
- Do not re-read the Layout Preset or Launch Override for an existing session.
- If the target Workspace Session does not exist, create it from the selected Pane Layout.

### Append Window mode

With `--append-window`:

- Resolve the target Workspace Session from the Launch Directory using existing session naming rules.
- Always resolve the selected Pane Layout.
- If the Workspace Session exists, create a new tmux window in that session and materialize the selected Pane Layout in it.
- If the Workspace Session does not exist, create the Workspace Session and materialize the selected Pane Layout in the initial window.
- By default, enter the target Workspace Session after creating or appending the window.
- With `--no-attach`, create or append the window without entering or switching the client.

### Examples

```sh
bin/tms -A
bin/tms -A --preset dev
bin/tms -A --file ./layouts.yml --preset dev
bin/tms -A --layout ./debug.yml
bin/tms -A --no-attach --preset logs
```

### Conflicting options

`--append-window` and `--recreate` are mutually exclusive because one appends to a Workspace Session while the other discards and rebuilds it.

Expected error:

```text
tms: --append-window cannot be combined with --recreate
```

Existing conflicts remain unchanged. In particular, `--layout` cannot be combined with `--preset` or `--file`.

## Window Naming

The appended or initial window name is derived from the selected layout source:

- Explicit preset: `--preset dev` creates window name `dev`.
- Default preset: when `default` is selected implicitly, window name is `default`.
- Single available preset: when selected implicitly, window name is that preset name.
- Launch Override: `--layout ./debug.yml` creates window name `debug`.
- No preset file: fallback single shell pane creates window name `shell`.

If a Launch Override basename cannot produce a usable name, use `layout`.

## Architecture

### Selected layout result

Current layout selection returns only a `PaneLayout`. Add a small result object so CLI flow receives both the selected layout and the window name:

```ruby
SelectedLayout = Struct.new(:layout, :window_name, keyword_init: true)
```

Suggested selection rules:

- Preset document selection returns the selected preset's `layout` and `name`.
- Launch Override returns the loaded `PaneLayout` and a window name derived from the layout file basename.
- Missing preset file returns `PaneLayout.leaf` and `shell`.

This keeps source-specific naming inside selection code rather than scattering it across `CLI#run`.

### TmuxPlan expansion

Keep existing session creation behavior but allow initial window naming:

```ruby
TmuxPlan.build(session:, start_directory:, layout:, window_name: nil)
```

Add an append plan:

```ruby
TmuxPlan.append_window(session:, window_name:, start_directory:, layout:)
```

The append plan should create steps equivalent to:

1. `:new_window`
2. materialize the Pane Layout into the new window's first pane
3. `:select_pane` for the new window's first pane

The existing `materialize` method should remain the shared path for nested panes, Pane Commands, titles, and `cwd` resolution.

### Tmux adapter

Add support for a `:new_window` plan step. It should use tmux's pane id output so later split and command steps can target the actual pane:

```sh
tmux new-window -d -P -F '#{pane_id}' -t <session> -n <window_name> -c <start_directory>
```

The returned pane id maps the logical target for the new window's first pane. Existing `split_window`, `send_command`, `open_shell`, and `select_pane` steps then continue using `pane_target` indirection.

### CLI flow

Pseudo-flow:

```ruby
parse!
launch_directory = File.expand_path(@options[:launch_directory])
identity = SessionName.resolve(launch_directory, git: @git)

if @options[:append_window]
  selected = selected_layout(launch_directory)

  if @tmux.session_exists?(identity.tmux_name)
    TmuxPlan.append_window(
      session: identity.tmux_name,
      window_name: selected.window_name,
      start_directory: launch_directory,
      layout: selected.layout
    ).execute(tmux: @tmux)
  else
    TmuxPlan.build(
      session: identity.tmux_name,
      window_name: selected.window_name,
      start_directory: launch_directory,
      layout: selected.layout
    ).execute(tmux: @tmux)
  end

  prepare_terminal_title(identity)
  enter_or_print(identity.tmux_name)
  return 0
end

# existing normal flow remains unchanged
```

`enter_or_print` already respects `--no-attach`, so append mode can reuse it.

## Error Handling

- Reject `--append-window --recreate` during option validation before tmux operations run.
- Reuse existing config errors for unreadable preset documents, unreadable one-off layout documents, ambiguous Preset Selection, and `--layout` conflicts.
- Let tmux command failures surface through existing `TmuxError` handling.
- Keep terminal title setup non-fatal.

## Testing Plan

### Option parsing and help

- Help includes `-A, --append-window`.
- `--append-window --recreate` returns the expected config error.
- Existing `--layout` conflict behavior remains covered.

### Selected layout naming

- `--preset dev` produces `window_name == "dev"`.
- Implicit `default` selection produces `window_name == "default"`.
- Single implicit preset selection produces that preset name.
- `--layout ./debug.yml` produces `window_name == "debug"`.
- Missing preset file fallback produces `window_name == "shell"`.

### Plan generation

- Append plan contains `:new_window` and no `:new_session`.
- Append plan materializes nested Pane Layouts into the new window target.
- Session creation with append mode names the initial window with the selected window name.

### CLI flow

- Existing session plus `-A --preset dev` appends a window and then enters the Workspace Session.
- Existing session plus `-A --no-attach` appends a window but does not enter.
- Missing session plus `-A` creates the Workspace Session from the selected layout.
- Existing session without `-A` keeps old early attach behavior and does not append a window.

### Final verification

Run:

```sh
make check
```

This should cover Ruby tests plus syntax checks for `lib/tms.rb` and `bin/tms`.

## Open Decisions

None. The current approved scope is `-A, --append-window` with automatic window naming, no `--recreate` combination, no multi-window preset format, and no compatibility behavior beyond existing option semantics.
