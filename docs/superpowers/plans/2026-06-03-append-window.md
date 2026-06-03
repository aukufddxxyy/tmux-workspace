# Append Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `-A, --append-window` so `tms` can append a selected Pane Layout as a new tmux window in the target Workspace Session.

**Architecture:** Keep Pane Layout single-window. Add a `SelectedLayout` value object that carries both the selected `PaneLayout` and the derived tmux window name, then add a `TmuxPlan.append_window` path that uses the same `materialize` logic as session creation. `CLI#run` branches early only for append mode; normal existing-session attach behavior stays unchanged.

**Tech Stack:** Ruby stdlib, OptionParser, Minitest, tmux CLI commands, Makefile `make check`.

---

## Current Worktree Note

At plan-writing time, the worktree has uncommitted edits from the earlier global config directory rename in these files:

- `AGENTS.md`
- `Makefile`
- `README.md`
- `lib/tms.rb`
- `test/makefile_test.rb`

Before executing this plan, keep those edits separate from append-window commits. If the user wants a clean history, commit the global config directory rename first with its own Lore-style commit. Do not revert those changes unless the user asks.

## File Structure

- Modify `lib/tms.rb`
  - Add `SelectedLayout` near `Preset`.
  - Add window-name derivation helpers in `CLI` or a small module near layout selection.
  - Extend `TmuxPlan.build` with optional `window_name:`.
  - Add `TmuxPlan.append_window`.
  - Add `:new_window` support in `Tmux#apply`.
  - Add `-A, --append-window` option and option conflict validation.
  - Change `CLI#selected_layout` to return `SelectedLayout`.
  - Branch `CLI#run` for append mode.
- Modify `test/tms_test.rb`
  - Add tests for help/options, selected layout naming, append plan generation, and CLI append flow.
  - Extend `fake_tmux` to record plan steps and make entering observable.
- Modify `README.md`
  - Document `-A/--append-window` usage and behavior.
- Modify `AGENTS.md`
  - Update project guidance with append-window behavior if implementation changes domain rules.
- Do not create new dependencies or new runtime files.

---

### Task 1: Add option validation for `-A, --append-window`

**Files:**
- Modify: `lib/tms.rb`
- Modify: `test/tms_test.rb`

- [ ] **Step 1: Write failing tests for help output and recreate conflict**

Add these tests in `test/tms_test.rb` before the `private` section:

```ruby
  def test_help_lists_append_window_option
    out = StringIO.new

    assert_raises(SystemExit) do
      Tms::CLI.new(
        ["--help"],
        env: {},
        out: out,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      ).run
    end

    assert_includes out.string, "-A, --append-window"
  end

  def test_append_window_cannot_be_combined_with_recreate
    err = StringIO.new
    cli = Tms::CLI.new(
      ["--append-window", "--recreate"],
      env: {},
      out: StringIO.new,
      err: err,
      stdin: StringIO.new,
      tmux: fake_tmux(session_exists: false),
      git: fake_git(false)
    )

    assert_equal 1, cli.run
    assert_includes err.string, "--append-window cannot be combined with --recreate"
  end
```

- [ ] **Step 2: Run the focused tests and verify they fail for the right reason**

Run:

```sh
ruby test/tms_test.rb --name '/append_window|help_lists/'
```

Expected: failure because help does not include `-A, --append-window`, and the recreate conflict is not rejected.

- [ ] **Step 3: Implement minimal option parsing**

In `CLI#initialize`, add `append_window: false` to `@options`:

```ruby
      @options = {
        launch_directory: Dir.pwd,
        attach: true,
        recreate: false,
        append_window: false
      }
```

In `CLI#parse!`, add the option after `--layout`:

```ruby
        opts.on("-A", "--append-window", "Append a window to the workspace session") { @options[:append_window] = true }
```

After the existing `--layout` conflict check, add:

```ruby
      raise ConfigError, "--append-window cannot be combined with --recreate" if @options[:append_window] && @options[:recreate]
```

- [ ] **Step 4: Run focused tests and verify they pass**

Run:

```sh
ruby test/tms_test.rb --name '/append_window|help_lists/'
```

Expected: 2 runs, 0 failures.

- [ ] **Step 5: Commit Task 1**

Stage only files changed for this task:

```sh
git add lib/tms.rb test/tms_test.rb
git commit -m "Guard append-window option semantics" -m "The append-window mode must be explicit and must not be combined with recreate because one preserves an existing Workspace Session while the other discards it.\n\nConstraint: CLI behavior must reject destructive/conflicting combinations before tmux operations run\nConfidence: high\nScope-risk: narrow\nTested: ruby test/tms_test.rb --name '/append_window|help_lists/'\nNot-tested: Full make check deferred until all append-window tasks are integrated"
```

---

### Task 2: Return selected layout with derived window name

**Files:**
- Modify: `lib/tms.rb`
- Modify: `test/tms_test.rb`

- [ ] **Step 1: Write failing tests for selected layout names through CLI flow**

Add helper support first in `fake_tmux` so tests can inspect applied steps. Replace the fake body with this expanded version:

```ruby
  def fake_tmux(session_exists:)
    Class.new do
      define_method(:initialize) do
        @session_exists = session_exists
        @entered = false
        @steps = []
      end

      define_method(:session_exists?) { |_name| @session_exists }
      define_method(:kill_session) { |_name| @session_exists = false }
      define_method(:enter_session) { |_name| @entered = true }
      define_method(:entered?) { @entered }
      define_method(:apply) { |step| @steps << step }
      define_method(:steps) { @steps }
      define_method(:set_terminal_title) { |session, title| @terminal_title = [session, title] }
      define_method(:terminal_title) { @terminal_title }
    end.new
  end
```

Add these tests before the `private` section:

```ruby
  def test_append_window_uses_explicit_preset_name_for_new_session_window
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          default:
            layout:
              command: nvim
          dev:
            layout:
              command: pnpm dev
      YAML
      tmux = fake_tmux(session_exists: false)

      cli = Tms::CLI.new(
        ["-A", "--preset", "dev", "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_session, File.basename(dir).tr(" ", "_"), dir, "dev"]
    end
  end

  def test_append_window_uses_default_preset_name_when_selected_implicitly
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          default:
            layout:
              command: nvim
      YAML
      tmux = fake_tmux(session_exists: false)

      cli = Tms::CLI.new(
        ["-A", "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_session, File.basename(dir).tr(" ", "_"), dir, "default"]
    end
  end

  def test_append_window_uses_single_preset_name_when_selected_implicitly
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          logs:
            layout:
              command: tail -f app.log
      YAML
      tmux = fake_tmux(session_exists: false)

      cli = Tms::CLI.new(
        ["-A", "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_session, File.basename(dir).tr(" ", "_"), dir, "logs"]
    end
  end

  def test_append_window_uses_layout_file_basename_for_one_off_layout
    Dir.mktmpdir("tms-layout") do |dir|
      layout_path = File.join(dir, "debug.yml")
      File.write(layout_path, <<~YAML)
        command: ruby -v
      YAML
      tmux = fake_tmux(session_exists: false)

      cli = Tms::CLI.new(
        ["-A", "--layout", layout_path, "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_session, File.basename(dir).tr(" ", "_"), dir, "debug"]
    end
  end

  def test_append_window_uses_shell_name_when_no_preset_file_exists
    Dir.mktmpdir("tms-layout") do |dir|
      tmux = fake_tmux(session_exists: false)

      cli = Tms::CLI.new(
        ["-A", "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_session, File.basename(dir).tr(" ", "_"), dir, "shell"]
    end
  end
```

- [ ] **Step 2: Run the focused naming tests and verify they fail**

Run:

```sh
ruby test/tms_test.rb --name '/uses_.*name|layout_file_basename|shell_name/'
```

Expected: failures because `CLI#run` does not yet use append mode and `:new_session` steps do not carry a window name.

- [ ] **Step 3: Add `SelectedLayout` and selection naming**

Near the existing `Preset` struct in `lib/tms.rb`, add:

```ruby
  SelectedLayout = Struct.new(:layout, :window_name, keyword_init: true)
```

Replace `CLI#selected_layout` with:

```ruby
    def selected_layout(launch_directory)
      if @options[:layout]
        return SelectedLayout.new(
          layout: LayoutDocument.load_file(@options[:layout]),
          window_name: layout_window_name(@options[:layout])
        )
      end

      preset_path = PresetLookup.find(explicit_file: @options[:file], launch_directory: launch_directory)
      return SelectedLayout.new(layout: PaneLayout.leaf, window_name: "shell") unless File.file?(preset_path)

      document = PresetDocument.load_file(preset_path)
      preset = PresetSelection.select(document, @options[:preset])
      SelectedLayout.new(layout: preset.layout, window_name: preset.name)
    end

    def layout_window_name(path)
      basename = File.basename(path.to_s, File.extname(path.to_s))
      basename.empty? ? "layout" : basename
    end
```

- [ ] **Step 4: Update normal `CLI#run` to unwrap `SelectedLayout`**

In the existing non-append creation path, change:

```ruby
      layout = selected_layout(launch_directory)
      TmuxPlan.build(session: identity.tmux_name, start_directory: launch_directory, layout: layout).execute(tmux: @tmux)
```

to:

```ruby
      selected = selected_layout(launch_directory)
      TmuxPlan.build(session: identity.tmux_name, start_directory: launch_directory, layout: selected.layout).execute(tmux: @tmux)
```

- [ ] **Step 5: Add append branch for missing sessions using initial window name**

In `CLI#run`, after resolving `identity` and before the existing `session_exists?` block, add:

```ruby
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
```

This step references `TmuxPlan.append_window`; Task 3 defines it. If the naming tests still fail with `undefined method append_window`, continue directly to Task 3 before expecting green for existing-session append paths. The missing-session tests in this task should pass after `TmuxPlan.build` accepts `window_name:`.

- [ ] **Step 6: Extend `TmuxPlan.build` to accept initial window name**

Change the method signature and first step:

```ruby
    def self.build(session:, start_directory:, layout:, window_name: nil)
      new.tap do |plan|
        plan.add(:new_session, session, start_directory, window_name)
        plan.materialize(layout, "#{session}:0.0", start_directory)
        plan.add(:select_pane, "#{session}:0.0")
      end
    end
```

- [ ] **Step 7: Run focused naming tests**

Run:

```sh
ruby test/tms_test.rb --name '/uses_.*name|layout_file_basename|shell_name/'
```

Expected: naming tests for missing-session `-A` pass after Task 3 is also completed; if they fail before Task 3 because `append_window` is undefined for existing sessions, finish Task 3 and rerun.

- [ ] **Step 8: Commit Task 2 after focused tests pass**

```sh
git add lib/tms.rb test/tms_test.rb
git commit -m "Carry selected layout names into launch planning" -m "Append-window needs to name the target window from the selected preset or launch override, so layout selection now returns both the Pane Layout and its derived window name.\n\nConstraint: Window naming must follow existing Preset Selection and Launch Override semantics\nRejected: Guess names inside CLI flow | would scatter source-specific naming rules\nConfidence: high\nScope-risk: moderate\nTested: ruby test/tms_test.rb --name '/uses_.*name|layout_file_basename|shell_name/'\nNot-tested: Full make check deferred until tmux append plan support lands"
```

---

### Task 3: Add append-window plan generation and tmux adapter support

**Files:**
- Modify: `lib/tms.rb`
- Modify: `test/tms_test.rb`

- [ ] **Step 1: Write failing plan tests**

Add these tests before the `private` section:

```ruby
  def test_append_window_plan_creates_window_without_new_session
    layout = Tms::PaneLayout.branch(
      "horizontal",
      [
        Tms::PaneLayout.leaf(command: "nvim", title: "editor"),
        Tms::PaneLayout.leaf(title: "shell")
      ],
      ratio: [40, 60]
    )

    plan = Tms::TmuxPlan.append_window(
      session: "repo_main",
      window_name: "dev",
      start_directory: "/repo",
      layout: layout
    )

    refute_includes plan.steps.map(&:first), :new_session
    assert_equal [:new_window, "repo_main", "repo_main:append.0", "dev", "/repo"], plan.steps[0]
    assert_includes plan.steps, [:split_window, "repo_main:append.0", "repo_main:append.1", "-h", "/repo", 60]
    assert_includes plan.steps, [:send_command, "repo_main:append.0", "nvim", "editor", "/repo"]
    assert_includes plan.steps, [:open_shell, "repo_main:append.1", "shell", "/repo"]
    assert_equal [:select_pane, "repo_main:append.0"], plan.steps.last
  end

  def test_new_session_plan_can_name_initial_window
    layout = Tms::PaneLayout.leaf(command: "nvim")

    plan = Tms::TmuxPlan.build(
      session: "repo_main",
      start_directory: "/repo",
      layout: layout,
      window_name: "dev"
    )

    assert_equal [:new_session, "repo_main", "/repo", "dev"], plan.steps[0]
  end
```

- [ ] **Step 2: Run plan tests and verify they fail**

Run:

```sh
ruby test/tms_test.rb --name '/append_window_plan|name_initial_window/'
```

Expected: failure because `TmuxPlan.append_window` does not exist and `TmuxPlan.build` currently does not include a window-name argument unless Task 2 already changed it.

- [ ] **Step 3: Implement `TmuxPlan.append_window`**

In `class TmuxPlan`, add:

```ruby
    def self.append_window(session:, window_name:, start_directory:, layout:)
      new.tap do |plan|
        target = "#{session}:append.0"
        plan.add(:new_window, session, target, window_name, start_directory)
        plan.materialize(layout, target, start_directory)
        plan.add(:select_pane, target)
      end
    end
```

- [ ] **Step 4: Add `:new_window` and named `:new_session` support in `Tmux#apply`**

Replace the `:new_session` branch with:

```ruby
      when :new_session
        session, cwd, window_name = args
        argv = ["tmux", "new-session", "-d", "-P", "-F", '#{pane_id}', "-s", session, "-c", cwd]
        argv.concat(["-n", window_name]) if window_name && !window_name.empty?
        pane_id = run!(*argv).strip
        @pane_targets["#{session}:0.0"] = pane_id
```

Add this branch after `:new_session`:

```ruby
      when :new_window
        session, target, window_name, cwd = args
        argv = ["tmux", "new-window", "-d", "-P", "-F", '#{pane_id}', "-t", session, "-c", cwd]
        argv.concat(["-n", window_name]) if window_name && !window_name.empty?
        @pane_targets[target] = run!(*argv).strip
```

- [ ] **Step 5: Run focused plan tests**

Run:

```sh
ruby test/tms_test.rb --name '/append_window_plan|name_initial_window/'
```

Expected: 2 runs, 0 failures.

- [ ] **Step 6: Run selected-layout naming tests from Task 2**

Run:

```sh
ruby test/tms_test.rb --name '/uses_.*name|layout_file_basename|shell_name/'
```

Expected: 5 runs, 0 failures.

- [ ] **Step 7: Commit Task 3**

```sh
git add lib/tms.rb test/tms_test.rb
git commit -m "Plan tmux windows separately from sessions" -m "Appending a window needs a plan entry that creates a new tmux window while reusing the existing Pane Layout materialization path for panes and commands.\n\nConstraint: Pane Layout remains single-window and must be materialized consistently in both creation and append paths\nRejected: Shelling out directly from CLI | would bypass TmuxPlan test coverage and target mapping\nConfidence: high\nScope-risk: moderate\nTested: ruby test/tms_test.rb --name '/append_window_plan|name_initial_window/'; ruby test/tms_test.rb --name '/uses_.*name|layout_file_basename|shell_name/'\nNot-tested: Full make check deferred until CLI append flow tests are complete"
```

---

### Task 4: Complete CLI append flow behavior

**Files:**
- Modify: `lib/tms.rb`
- Modify: `test/tms_test.rb`

- [ ] **Step 1: Write failing CLI flow tests**

Add these tests before the `private` section:

```ruby
  def test_existing_session_with_append_window_adds_window_and_enters
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          dev:
            layout:
              command: pnpm dev
      YAML
      tmux = fake_tmux(session_exists: true)

      cli = Tms::CLI.new(
        ["-A", "--preset", "dev", "-C", dir],
        env: {},
        out: tty_string_io,
        err: StringIO.new,
        stdin: tty_string_io,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_window, File.basename(dir).tr(" ", "_"), "#{File.basename(dir).tr(" ", "_")}:append.0", "dev", dir]
      assert_equal true, tmux.entered?
    end
  end

  def test_existing_session_with_append_window_and_no_attach_does_not_enter
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          dev:
            layout:
              command: pnpm dev
      YAML
      tmux = fake_tmux(session_exists: true)

      cli = Tms::CLI.new(
        ["-A", "--preset", "dev", "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes tmux.steps, [:new_window, File.basename(dir).tr(" ", "_"), "#{File.basename(dir).tr(" ", "_")}:append.0", "dev", dir]
      assert_equal false, tmux.entered?
    end
  end

  def test_existing_session_without_append_window_keeps_early_attach_behavior
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          dev:
            layout:
              command: pnpm dev
      YAML
      tmux = fake_tmux(session_exists: true)

      cli = Tms::CLI.new(
        ["--preset", "dev", "-C", dir],
        env: {},
        out: tty_string_io,
        err: StringIO.new,
        stdin: tty_string_io,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_equal [], tmux.steps
      assert_equal true, tmux.entered?
    end
  end
```

- [ ] **Step 2: Run CLI flow tests and verify they fail if append branch is incomplete**

Run:

```sh
ruby test/tms_test.rb --name '/existing_session_with_append_window|early_attach_behavior/'
```

Expected before implementation: append tests fail because existing sessions attach early instead of appending; the non-append early attach test should pass or continue passing.

- [ ] **Step 3: Implement final append branch in `CLI#run`**

Ensure the append branch appears after `identity` resolution and before the existing `if @tmux.session_exists?` block:

```ruby
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
```

Ensure the normal creation path still unwraps selected layout:

```ruby
      selected = selected_layout(launch_directory)
      TmuxPlan.build(session: identity.tmux_name, start_directory: launch_directory, layout: selected.layout).execute(tmux: @tmux)
```

- [ ] **Step 4: Run CLI flow tests**

Run:

```sh
ruby test/tms_test.rb --name '/existing_session_with_append_window|early_attach_behavior/'
```

Expected: 3 runs, 0 failures.

- [ ] **Step 5: Commit Task 4**

```sh
git add lib/tms.rb test/tms_test.rb
git commit -m "Append selected layouts to existing workspaces" -m "The append-window launch mode must bypass the normal existing-session early attach path so it can add a new window while preserving ordinary attach behavior for commands without -A.\n\nConstraint: --no-attach must still suppress entering after append\nRejected: Reusing normal existing-session branch | it never resolves the selected layout or appends a window\nConfidence: high\nScope-risk: moderate\nTested: ruby test/tms_test.rb --name '/existing_session_with_append_window|early_attach_behavior/'\nNot-tested: Full make check deferred until docs are updated"
```

---

### Task 5: Document append-window behavior

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: Add README usage examples**

In `README.md`, extend the Usage block to include append-window examples:

```markdown
bin/tms --append-window --preset dev
bin/tms -A --layout ./debug.yml
```

- [ ] **Step 2: Document append behavior after existing session paragraph**

After the paragraph that says existing sessions attach and `--recreate` kills/rebuilds, add:

```markdown
Use `-A, --append-window` to add a new window to the target Workspace Session instead of only attaching to an existing session. The new window uses the selected preset or one-off layout. When the Workspace Session does not exist yet, append-window mode creates it and names the initial window from the selected layout. `--append-window` cannot be combined with `--recreate`.
```

- [ ] **Step 3: Document window naming**

After the One-Off Layout section, add:

```markdown
## Append Window

`--append-window` derives the tmux window name from the selected layout source:

- `--preset dev` names the window `dev`
- an implicit `default` preset names the window `default`
- a single implicit preset uses that preset name
- `--layout ./debug.yml` names the window `debug`
- no preset file creates a single shell pane named `shell`

By default, `tms` enters the Workspace Session after appending the window. Add `--no-attach` to create the window without entering or switching the client.
```

- [ ] **Step 4: Update AGENTS domain rules**

In `AGENTS.md`, add one bullet under Domain Rules:

```markdown
- `-A` / `--append-window` is an append launch mode for the target Workspace Session: it reuses Preset Selection or Launch Override to create a new tmux window, names that window from the selected layout source, and cannot be combined with Session Recreate.
```

- [ ] **Step 5: Run help smoke check**

Run:

```sh
bin/tms --help
```

Expected: output includes `-A, --append-window` and exits successfully.

- [ ] **Step 6: Commit Task 5**

```sh
git add README.md AGENTS.md
git commit -m "Document append-window workspace behavior" -m "Users need the append-window mode documented alongside existing preset and launch override behavior because it changes what happens when a Workspace Session already exists.\n\nConstraint: Documentation must use CONTEXT.md vocabulary for Workspace Session, Preset Selection, Launch Override, and Session Recreate\nConfidence: high\nScope-risk: narrow\nTested: bin/tms --help\nNot-tested: Full make check deferred to final verification task"
```

---

### Task 6: Full verification and final cleanup

**Files:**
- Review: `lib/tms.rb`
- Review: `test/tms_test.rb`
- Review: `README.md`
- Review: `AGENTS.md`

- [ ] **Step 1: Run full check**

Run:

```sh
make check
```

Expected:

- `ruby test/tms_test.rb` passes with 0 failures.
- `ruby test/makefile_test.rb` passes with 0 failures.
- `ruby -c lib/tms.rb` prints `Syntax OK`.
- `ruby -c bin/tms` prints `Syntax OK`.

- [ ] **Step 2: Check for stale or contradictory append docs**

Run:

```sh
grep -R "append-window\|append_window\|Append Window" -n -- README.md AGENTS.md lib/tms.rb test/tms_test.rb docs/superpowers/specs docs/superpowers/plans
```

Expected: references agree on `-A, --append-window`, selected layout naming, and `--recreate` conflict.

- [ ] **Step 3: Inspect final diff**

Run:

```sh
git diff --stat
git diff -- lib/tms.rb test/tms_test.rb README.md AGENTS.md
```

Expected: diff only contains append-window implementation/docs plus any intentionally separate pre-existing global config directory rename if it has not already been committed separately.

- [ ] **Step 4: Commit final verification if there are final-only adjustments**

If Step 2 or Step 3 required a correction, commit only that correction:

```sh
git add lib/tms.rb test/tms_test.rb README.md AGENTS.md
git commit -m "Tighten append-window verification coverage" -m "Final verification found small consistency issues after the append-window implementation, so this commit keeps tests and documentation aligned.\n\nConstraint: make check is the repository's full verification command\nConfidence: high\nScope-risk: narrow\nTested: make check\nNot-tested: Live tmux manual append in an interactive terminal"
```

If no correction was required, do not create an empty commit.

- [ ] **Step 5: Report completion evidence**

Final report must include:

- Changed files.
- Simplifications made.
- Verification evidence from `make check`.
- Remaining risk: live tmux append behavior should be smoke-tested manually if the implementer has a safe tmux session available; automated tests fake tmux command execution.
