# tmux Scripts

This context describes the language for launching repeatable tmux workspaces from arbitrary directories.

## Language

**Workspace Session**:
A tmux session created for a working directory, named from the directory and its Git/worktree relationship.
_Avoid_: project session, auto session

**Session Display Name**:
The human naming form for a **Workspace Session**, written as `PrimaryWorktree:WorktreeRoot` or `Directory:main` depending on Git context.
_Avoid_: tmux session name, raw session name

**Tmux Session Name**:
The tmux-safe form of a **Session Display Name**, using `_` as the separator instead of `:`.
_Avoid_: display name, target name

**Session Recreate**:
An explicit launch choice that discards an existing **Workspace Session** with the same name and creates it again from the selected **Pane Layout**.
_Avoid_: refresh, reload

**Primary Worktree**:
The main Git working tree reported for a repository, used as the stable naming anchor for related worktrees. Its display label is `main` even when the actual Git branch has a different name.
_Avoid_: main branch, default branch

**Worktree Root**:
The filesystem root of the Git working tree that contains the launch directory. Git-backed **Workspace Session** names use Worktree Root names rather than nested launch directory names.
_Avoid_: current folder, project folder

**Launch Directory**:
The directory where the launcher is invoked. Pane Commands run from the Launch Directory unless a pane explicitly chooses another working directory.
_Avoid_: session directory, project root

**Pane Command**:
A command assigned to one tmux pane when a **Workspace Session** starts. After the command finishes, the pane remains available as an interactive shell.
_Avoid_: panel script, startup script

**Layout Preset**:
A reusable **Pane Layout** and its **Pane Commands** within a single tmux window.
_Avoid_: template, profile

**Preset Document**:
A YAML document that defines one or more **Layout Presets**.
_Avoid_: config blob, shell profile

**Preset Lookup**:
The ordered search for a **Preset Document**, from an explicit launch file, to the nearest directory-local document, to the user-global document.
_Avoid_: config discovery, settings resolution

**Preset Selection**:
The choice of which **Layout Preset** to launch from a **Preset Document**. The default selection prefers a preset named `default`, then a single available preset when it is unambiguous.
_Avoid_: profile picking, config mode

**Pane Layout**:
A single-window split structure that can represent nested tmux panes, such as a left pane beside two stacked right panes. A Pane Layout may include sizing ratios for panes at the same split level.
_Avoid_: split mode, window layout

**Launch Override**:
A complete one-off **Pane Layout** selected at launch time that replaces any **Layout Preset** for the current **Workspace Session**.
_Avoid_: parameter hack, ad hoc config

## Example Dialogue

Dev: "I want to start a Workspace Session here using my web Layout Preset."

Domain expert: "Use the preset, then add a Launch Override if this run needs a different Pane Command."
