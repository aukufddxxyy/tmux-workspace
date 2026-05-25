# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"

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

    assert_equal [:new_session, "repo_main", "/repo/apps/web"], plan.steps[0]
    assert_includes plan.steps, [:split_window, "repo_main:0.0", "repo_main:0.1", "-h", "/repo/apps/web", 70]
    assert_includes plan.steps, [:split_window, "repo_main:0.1", "repo_main:0.2", "-v", "/repo/apps/web", 40]
    assert_includes plan.steps, [:send_command, "repo_main:0.0", "nvim", "editor", "/repo/apps/web"]
    assert_includes plan.steps, [:send_command, "repo_main:0.1", "pnpm dev", "server", "/repo/apps/web"]
    assert_includes plan.steps, [:open_shell, "repo_main:0.2", "shell", "/repo/apps/web"]
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

  def test_errors_when_explicit_preset_file_is_missing
    error = assert_raises(Tms::ConfigError) do
      Tms::PresetDocument.load_file("/definitely/missing.yml")
    end

    assert_match(/Cannot read/, error.message)
  end

  private

  def fake_git(inside, common_dir: nil, worktrees: [])
    Class.new do
      define_method(:inside_work_tree?) { |_dir| inside }
      define_method(:common_dir) { |_dir| common_dir }
      define_method(:worktrees) { |_dir| worktrees }
    end.new
  end
end
