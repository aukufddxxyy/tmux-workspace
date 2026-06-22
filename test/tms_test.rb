# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"

require_relative "../lib/tms"

class TmsTest < Minitest::Test
  def test_sanitizes_session_display_name_for_tmux
    assert_equal "我的_项目_main", Tms::SessionName.safe("我的 项目:main")
  end

  def test_names_non_git_directory_from_launch_directory
    Dir.mktmpdir("plain project") do |dir|
      assert_match(/\Aplain_project/, Tms::SessionName.resolve(dir, git: fake_git(false)).tmux_name)
    end
  end

  def test_names_primary_worktree_as_root_main
    git = fake_git(
      true,
      common_dir: "/repo/.git",
      worktrees: [
        { path: "/repo", primary: true },
        { path: "/repo-feature", primary: false }
      ]
    )

    name = Tms::SessionName.resolve("/repo/apps/web", git: git)

    assert_equal "repo:main", name.display_name
    assert_equal "repo_main", name.tmux_name
  end

  def test_names_linked_worktree_from_primary_and_current_worktree_roots
    git = fake_git(
      true,
      common_dir: "/repo/.git",
      worktrees: [
        { path: "/repo", primary: true },
        { path: "/repo-feature", primary: false }
      ]
    )

    name = Tms::SessionName.resolve("/repo-feature/apps/web", git: git)

    assert_equal "repo:repo-feature", name.display_name
    assert_equal "repo_repo-feature", name.tmux_name
  end

  def test_terminal_title_sequence_uses_sanitized_display_name
    assert_equal "\033]0;repo:main\a", Tms::TerminalTitle.sequence("repo:\033main\a")
  end

  def test_selects_default_preset
    doc = Tms::PresetDocument.load_yaml(<<~YAML)
      presets:
        default:
          layout:
            command: nvim
        api:
          layout:
            command: pnpm dev
    YAML

    assert_equal "nvim", Tms::PresetSelection.select(doc).layout.command
  end

  def test_selects_only_preset_when_default_is_missing
    doc = Tms::PresetDocument.load_yaml(<<~YAML)
      presets:
        api:
          layout:
            command: pnpm dev
    YAML

    assert_equal "pnpm dev", Tms::PresetSelection.select(doc).layout.command
  end

  def test_errors_when_multiple_presets_have_no_default
    doc = Tms::PresetDocument.load_yaml(<<~YAML)
      presets:
        api:
          layout:
            command: pnpm dev
        test:
          layout:
            command: pnpm test
    YAML

    error = assert_raises(Tms::ConfigError) { Tms::PresetSelection.select(doc) }
    assert_match(/--preset/, error.message)
  end

  def test_parses_nested_layout_with_ratio_title_and_empty_shell_pane
    doc = Tms::PresetDocument.load_yaml(<<~YAML)
      presets:
        default:
          layout:
            split: horizontal
            ratio: [30, 70]
            panes:
              - title: editor
                command: nvim
              - split: vertical
                panes:
                  - title: server
                    command: pnpm dev
                  - title: shell
    YAML

    layout = Tms::PresetSelection.select(doc).layout

    assert_equal "horizontal", layout.split
    assert_equal [30, 70], layout.ratio
    assert_equal "editor", layout.panes.first.title
    assert_equal "pnpm dev", layout.panes.last.panes.first.command
    assert_nil layout.panes.last.panes.last.command
  end

  def test_parses_one_off_layout_document_without_presets_wrapper
    layout = Tms::LayoutDocument.load_yaml(<<~YAML)
      split: horizontal
      panes:
        - command: nvim
        - title: shell
    YAML

    assert_equal "horizontal", layout.split
    assert_equal "nvim", layout.panes.first.command
    assert_nil layout.panes.last.command
  end

  def test_plans_tmux_commands_for_nested_layout
    layout = Tms::PaneLayout.branch(
      "horizontal",
      [
        Tms::PaneLayout.leaf(command: "nvim", title: "editor"),
        Tms::PaneLayout.branch(
          "vertical",
          [
            Tms::PaneLayout.leaf(command: "pnpm dev", title: "server"),
            Tms::PaneLayout.leaf(title: "shell")
          ],
          ratio: [60, 40]
        )
      ],
      ratio: [30, 70]
    )

    plan = Tms::TmuxPlan.build(session: "repo_main", start_directory: "/repo/apps/web", layout: layout)

    assert_equal [:new_session, "repo_main", "/repo/apps/web", nil], plan.steps[0]
    assert_includes plan.steps, [:split_window, "repo_main:0.0", "repo_main:0.1", "-h", "/repo/apps/web", 70]
    assert_includes plan.steps, [:split_window, "repo_main:0.1", "repo_main:0.2", "-v", "/repo/apps/web", 40]
    assert_includes plan.steps, [:send_command, "repo_main:0.0", "nvim", "editor", "/repo/apps/web"]
    assert_includes plan.steps, [:send_command, "repo_main:0.1", "pnpm dev", "server", "/repo/apps/web"]
    assert_includes plan.steps, [:open_shell, "repo_main:0.2", "shell", "/repo/apps/web"]
  end

  def test_name_initial_window_when_building_session_plan
    layout = Tms::PaneLayout.leaf(title: "shell")

    plan = Tms::TmuxPlan.build(session: "repo_main", start_directory: "/repo", layout: layout, window_name: "dev")

    assert_equal [:new_session, "repo_main", "/repo", "dev"], plan.steps.first
  end

  def test_append_window_plan_materializes_layout_into_append_window
    layout = Tms::PaneLayout.branch(
      "horizontal",
      [
        Tms::PaneLayout.leaf(command: "nvim", title: "editor"),
        Tms::PaneLayout.leaf(title: "shell")
      ]
    )

    plan = Tms::TmuxPlan.append_window(session: "repo_main", window_name: "dev", start_directory: "/repo", layout: layout)

    assert_equal [:new_window, "repo_main", "repo_main:append.0", "dev", "/repo"], plan.steps.first
    refute_includes plan.steps.map(&:first), :new_session
    assert_includes plan.steps, [:split_window, "repo_main:append.0", "repo_main:append.1", "-h", "/repo", nil]
    assert_includes plan.steps, [:send_command, "repo_main:append.0", "nvim", "editor", "/repo"]
    assert_includes plan.steps, [:open_shell, "repo_main:append.1", "shell", "/repo"]
    assert_equal [:select_pane, "repo_main:append.0"], plan.steps.last
  end

  def test_converts_three_pane_ratios_to_sequential_tmux_percentages
    layout = Tms::PaneLayout.branch(
      "horizontal",
      [
        Tms::PaneLayout.leaf(title: "one"),
        Tms::PaneLayout.leaf(title: "two"),
        Tms::PaneLayout.leaf(title: "three")
      ],
      ratio: [20, 30, 50]
    )

    plan = Tms::TmuxPlan.build(session: "repo_main", start_directory: "/repo", layout: layout)

    assert_includes plan.steps, [:split_window, "repo_main:0.0", "repo_main:0.1", "-h", "/repo", 30]
    assert_includes plan.steps, [:split_window, "repo_main:0.0", "repo_main:0.2", "-h", "/repo", 71]
  end

  def test_splits_sibling_panes_before_descending_into_nested_layouts
    layout = Tms::PaneLayout.branch(
      "horizontal",
      [
        Tms::PaneLayout.branch(
          "vertical",
          [
            Tms::PaneLayout.leaf(title: "top-left"),
            Tms::PaneLayout.leaf(title: "bottom-left")
          ],
          ratio: [50, 50]
        ),
        Tms::PaneLayout.branch(
          "vertical",
          [
            Tms::PaneLayout.leaf(title: "top-right"),
            Tms::PaneLayout.leaf(title: "bottom-right")
          ],
          ratio: [50, 50]
        )
      ],
      ratio: [50, 50]
    )

    plan = Tms::TmuxPlan.build(session: "repo_main", start_directory: "/repo", layout: layout)
    split_steps = plan.steps.select { |step| step.first == :split_window }

    assert_equal [
      [:split_window, "repo_main:0.0", "repo_main:0.1", "-h", "/repo", 50],
      [:split_window, "repo_main:0.0", "repo_main:0.2", "-v", "/repo", 50],
      [:split_window, "repo_main:0.1", "repo_main:0.3", "-v", "/repo", 50]
    ], split_steps
  end

  def test_errors_when_explicit_preset_file_is_missing
    error = assert_raises(Tms::ConfigError) do
      Tms::PresetDocument.load_file("/definitely/missing.yml")
    end

    assert_match(/Cannot read/, error.message)
  end

  def test_non_tty_cli_does_not_attempt_to_attach_created_session
    tmux = fake_tmux(session_exists: false)
    out = StringIO.new
    cli = Tms::CLI.new(
      [],
      env: {},
      out: out,
      err: StringIO.new,
      stdin: StringIO.new,
      tmux: tmux,
      git: fake_git(false)
    )

    assert_equal 0, cli.run
    assert_equal false, tmux.entered?
  end

  def test_cli_configures_terminal_title_for_existing_session_before_attach_hint
    tmux = fake_tmux(session_exists: true)
    cli = Tms::CLI.new(
      ["-C", "/work/plain project"],
      env: {},
      out: StringIO.new,
      err: StringIO.new,
      stdin: StringIO.new,
      tmux: tmux,
      git: fake_git(false)
    )

    assert_equal 0, cli.run
    assert_equal ["plain_project", "plain project"], tmux.terminal_title
  end

  def test_cli_prints_terminal_title_when_attaching_from_terminal
    tmux = fake_tmux(session_exists: true)
    out = tty_string_io
    cli = Tms::CLI.new(
      ["-C", "/work/plain project"],
      env: {},
      out: out,
      err: StringIO.new,
      stdin: tty_string_io,
      tmux: tmux,
      git: fake_git(false)
    )

    assert_equal 0, cli.run
    assert_includes out.string, Tms::TerminalTitle.sequence("plain project")
  end

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
    assert_includes out.string, "-R, --recreate"
  end

  def test_help_lists_preset_list_options
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

    assert_includes out.string, "-L, --list"
    assert_includes out.string, "--verbose"
  end

  def test_list_prints_available_preset_names_without_touching_tmux
    Dir.mktmpdir("tms-layout") do |dir|
      write_preset_file(dir)
      out = StringIO.new
      tmux = fake_tmux(session_exists: true)

      cli = Tms::CLI.new(
        ["--list", "-C", dir],
        env: {},
        out: out,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes out.string, "Available presets (from #{File.join(dir, ".tmux-layout.yml")}):"
      assert_includes out.string, "  default\n"
      assert_includes out.string, "  logs\n"
      assert_equal [], tmux.steps
      assert_equal false, tmux.entered?
    end
  end

  def test_list_verbose_prints_preset_structure_tree
    Dir.mktmpdir("tms-layout") do |dir|
      write_preset_file(dir)
      out = StringIO.new

      cli = Tms::CLI.new(
        ["--list", "--verbose", "--preset", "default", "-C", dir],
        env: {},
        out: out,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes out.string, "default:\n"
      assert_includes out.string, "  horizontal [30, 70]\n"
      assert_includes out.string, "  ├── editor: nvim\n"
      assert_includes out.string, "  └── vertical [60, 40]\n"
      assert_includes out.string, "      ├── server: pnpm dev\n"
      assert_includes out.string, "      └── shell\n"
    end
  end

  def test_list_named_preset_only_prints_that_preset
    Dir.mktmpdir("tms-layout") do |dir|
      write_preset_file(dir)
      out = StringIO.new

      cli = Tms::CLI.new(
        ["--list", "--preset", "logs", "-C", dir],
        env: {},
        out: out,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_equal "  logs\n", out.string
    end
  end

  def test_list_missing_preset_file_prints_hint_to_stderr
    Dir.mktmpdir("tms-layout") do |dir|
      err = StringIO.new

      cli = Tms::CLI.new(
        ["--list", "--file", File.join(dir, "missing.yml"), "-C", dir],
        env: {},
        out: StringIO.new,
        err: err,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes err.string, "No preset file found."
      assert_includes err.string, "Run 'make config'"
    end
  end

  def test_list_cannot_be_combined_with_layout
    err = StringIO.new

    cli = Tms::CLI.new(
      ["--list", "--layout", "layout.yml"],
      env: {},
      out: StringIO.new,
      err: err,
      stdin: StringIO.new,
      tmux: fake_tmux(session_exists: false),
      git: fake_git(false)
    )

    assert_equal 1, cli.run
    assert_includes err.string, "--list cannot be combined with --layout"
  end

  def test_list_cannot_be_combined_with_recreate
    err = StringIO.new

    cli = Tms::CLI.new(
      ["--list", "--recreate"],
      env: {},
      out: StringIO.new,
      err: err,
      stdin: StringIO.new,
      tmux: fake_tmux(session_exists: false),
      git: fake_git(false)
    )

    assert_equal 1, cli.run
    assert_includes err.string, "--list cannot be combined with --recreate"
  end

  def test_list_unknown_preset_reports_selection_error
    Dir.mktmpdir("tms-layout") do |dir|
      write_preset_file(dir)
      err = StringIO.new

      cli = Tms::CLI.new(
        ["--list", "--preset", "missing", "-C", dir],
        env: {},
        out: StringIO.new,
        err: err,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      )

      assert_equal 1, cli.run
      assert_includes err.string, 'Unknown preset "missing"'
    end
  end

  def test_list_uses_explicit_preset_file
    Dir.mktmpdir("tms-layout") do |dir|
      preset_path = File.join(dir, "custom.yml")
      File.write(preset_path, <<~YAML)
        presets:
          custom:
            layout:
              command: ruby -v
      YAML
      out = StringIO.new

      cli = Tms::CLI.new(
        ["--list", "--file", preset_path, "-C", dir],
        env: {},
        out: out,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes out.string, "Available presets (from #{preset_path}):"
      assert_includes out.string, "  custom\n"
    end
  end

  def test_list_verbose_prints_leaf_without_title_using_command_label
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          default:
            layout:
              command: ruby -v
      YAML
      out = StringIO.new

      cli = Tms::CLI.new(
        ["--list", "--verbose", "-C", dir],
        env: {},
        out: out,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: fake_tmux(session_exists: false),
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_includes out.string, "default:\n"
      assert_includes out.string, "  ruby -v\n"
      refute_includes out.string, ": ruby -v"
    end
  end

  def test_append_window_cannot_be_combined_with_recreate
    err = StringIO.new
    cli = Tms::CLI.new(
      ["-A", "-R"],
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

  def test_recreate_short_option_rebuilds_existing_session
    Dir.mktmpdir("tms-layout") do |dir|
      tmux = fake_tmux(session_exists: true)

      cli = Tms::CLI.new(
        ["-R", "--file", File.join(dir, "missing-layouts.yml"), "-C", dir, "--no-attach"],
        env: {},
        out: StringIO.new,
        err: StringIO.new,
        stdin: StringIO.new,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_equal [File.basename(dir).tr(" ", "_")], tmux.killed_sessions
      assert_includes tmux.steps, [:new_session, File.basename(dir).tr(" ", "_"), dir, nil]
    end
  end

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
        ["-A", "--file", File.join(dir, "missing-layouts.yml"), "-C", dir, "--no-attach"],
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

  def test_append_window_existing_session_applies_append_plan
    Dir.mktmpdir("tms-layout") do |dir|
      File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
        presets:
          default:
            layout:
              command: nvim
      YAML
      tmux = fake_tmux(session_exists: true)

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
      assert_includes tmux.steps, [:new_window, File.basename(dir).tr(" ", "_"), "#{File.basename(dir).tr(" ", "_")}:append.0", "default", dir]
      assert_includes tmux.steps, [:send_command, "#{File.basename(dir).tr(" ", "_")}:append.0", "nvim", nil, dir]
      assert_includes tmux.steps, [:select_pane, "#{File.basename(dir).tr(" ", "_")}:append.0"]
      assert_equal false, tmux.entered?
    end
  end

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
      err = StringIO.new

      cli = Tms::CLI.new(
        ["--preset", "missing", "-C", dir],
        env: {},
        out: tty_string_io,
        err: err,
        stdin: tty_string_io,
        tmux: tmux,
        git: fake_git(false)
      )

      assert_equal 0, cli.run
      assert_equal [], tmux.steps
      assert_equal true, tmux.entered?
      refute_match(/Unknown preset|Cannot read/, err.string)
    end
  end

  private

  def fake_git(inside, common_dir: nil, worktrees: [])
    Class.new do
      define_method(:inside_work_tree?) { |_dir| inside }
      define_method(:common_dir) { |_dir| common_dir }
      define_method(:worktrees) { |_dir| worktrees }
    end.new
  end

  def fake_tmux(session_exists:)
    Class.new do
      define_method(:initialize) do
        @session_exists = session_exists
        @entered = false
        @steps = []
        @killed_sessions = []
      end

      define_method(:session_exists?) { |_name| @session_exists }
      define_method(:kill_session) { |name| @killed_sessions << name; @session_exists = false }
      define_method(:enter_session) { |_name| @entered = true }
      define_method(:entered?) { @entered }
      define_method(:apply) { |step| @steps << step }
      define_method(:steps) { @steps }
      define_method(:killed_sessions) { @killed_sessions }
      define_method(:set_terminal_title) { |session, title| @terminal_title = [session, title] }
      define_method(:terminal_title) { @terminal_title }
    end.new
  end

  def tty_string_io
    Class.new(StringIO) do
      def tty?
        true
      end
    end.new
  end

  def write_preset_file(dir)
    File.write(File.join(dir, ".tmux-layout.yml"), <<~YAML)
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
        logs:
          layout:
            title: logs
            command: tail -f app.log
    YAML
  end
end
