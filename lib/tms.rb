# frozen_string_literal: true

require "etc"
require "open3"
require "optparse"
require "shellwords"
require "yaml"

module Tms
  class Error < StandardError; end
  class ConfigError < Error; end
  class TmuxError < Error; end

  SessionIdentity = Struct.new(:display_name, :tmux_name, keyword_init: true)
  Preset = Struct.new(:name, :layout, keyword_init: true)
  SelectedLayout = Struct.new(:layout, :window_name, keyword_init: true)

  module TerminalTitle
    module_function

    def sequence(title)
      "\033]0;#{sanitize(title)}\a"
    end

    def sanitize(title)
      title.to_s.delete("\033\a").gsub(/[[:cntrl:]]/, "")
    end
  end

  module SessionName
    module_function

    def resolve(launch_directory, git: Git.new)
      launch_directory = File.expand_path(launch_directory)

      unless git.inside_work_tree?(launch_directory)
        display = File.basename(launch_directory)
        return SessionIdentity.new(display_name: display, tmux_name: safe(display))
      end

      worktrees = git.worktrees(launch_directory)
      current = containing_worktree(launch_directory, worktrees)
      primary = worktrees.find { |worktree| worktree[:primary] } || current
      raise ConfigError, "Could not resolve git worktree root" unless current && primary

      primary_name = File.basename(primary[:path])
      current_name = current[:primary] ? "main" : current[:branch] || File.basename(current[:path])
      display = "#{primary_name}:#{current_name}"

      SessionIdentity.new(display_name: display, tmux_name: safe(display))
    end

    def safe(display_name)
      display_name
        .tr(":", "_")
        .gsub(/[[:space:]]+/, "_")
        .gsub(/_+/, "_")
        .gsub(/\A_+|_+\z/, "")
    end

    def containing_worktree(path, worktrees)
      expanded = File.expand_path(path)
      worktrees
        .sort_by { |worktree| -File.expand_path(worktree[:path]).length }
        .find do |worktree|
          root = File.expand_path(worktree[:path])
          expanded == root || expanded.start_with?("#{root}/")
        end
    end
  end

  class Git
    def inside_work_tree?(dir)
      success?("git", "-C", dir, "rev-parse", "--is-inside-work-tree")
    end

    def common_dir(dir)
      run!("git", "-C", dir, "rev-parse", "--git-common-dir")
    end

    def worktrees(dir)
      output = run!("git", "-C", dir, "worktree", "list", "--porcelain")
      parse_worktrees(output, common_dir(dir))
    end

    private

    def parse_worktrees(output, common)
      entries = []
      current = nil

      output.each_line do |line|
        line = line.chomp
        if line.start_with?("worktree ")
          entries << current if current
          current = { path: line.sub("worktree ", ""), primary: false }
        elsif line.start_with?("commondir ") && current
          current[:primary] = File.expand_path(line.sub("commondir ", "")) == File.expand_path(common)
        elsif line.start_with?("branch ") && current
          current[:branch] = line.sub("branch ", "").sub(%r{\Arefs/heads/}, "")
        end
      end

      entries << current if current
      entries.first[:primary] = true if entries.any? && entries.none? { |entry| entry[:primary] }
      entries
    end

    def success?(*argv)
      system(*argv, out: File::NULL, err: File::NULL)
    end

    def run!(*argv)
      output, status = Open3.capture2(*argv)
      raise ConfigError, "Command failed: #{argv.shelljoin}" unless status.success?

      output.strip
    end
  end

  class PaneLayout
    attr_reader :split, :panes, :ratio, :command, :title, :cwd

    def self.leaf(command: nil, title: nil, cwd: nil)
      new(command: command, title: title, cwd: cwd)
    end

    def self.branch(split, panes, ratio: nil, title: nil, cwd: nil)
      new(split: split, panes: panes, ratio: ratio, title: title, cwd: cwd)
    end

    def self.from_hash(value)
      raise ConfigError, "Layout must be a mapping" unless value.is_a?(Hash)

      if value.key?("panes") || value.key?(:panes)
        split = fetch_string(value, "split")
        panes = fetch_value(value, "panes")
        raise ConfigError, "Branch layout panes must be an array" unless panes.is_a?(Array)
        raise ConfigError, "Branch layout needs at least one pane" if panes.empty?

        ratio = fetch_optional(value, "ratio")
        if ratio && (!ratio.is_a?(Array) || ratio.length != panes.length)
          raise ConfigError, "Layout ratio must be an array matching panes length"
        end

        branch(split, panes.map { |pane| from_hash(pane) }, ratio: ratio, title: fetch_optional(value, "title"), cwd: fetch_optional(value, "cwd"))
      else
        leaf(command: fetch_optional(value, "command"), title: fetch_optional(value, "title"), cwd: fetch_optional(value, "cwd"))
      end
    end

    def initialize(split: nil, panes: nil, ratio: nil, command: nil, title: nil, cwd: nil)
      @split = split
      @panes = panes
      @ratio = ratio
      @command = command
      @title = title
      @cwd = cwd
      validate!
    end

    def leaf?
      panes.nil?
    end

    def branch?
      !leaf?
    end

    def direction_flag
      case split
      when "horizontal"
        "-h"
      when "vertical"
        "-v"
      else
        raise ConfigError, "Unsupported split direction: #{split.inspect}"
      end
    end

    def validate!
      return if leaf?

      raise ConfigError, "Branch layout must have split" if split.nil? || split.empty?
      raise ConfigError, "Branch layout must have panes" unless panes.is_a?(Array) && panes.any?
      if ratio && (!ratio.is_a?(Array) || ratio.length != panes.length)
        raise ConfigError, "Layout ratio must match panes length"
      end
    end

    def self.fetch_value(hash, key)
      hash.fetch(key) { hash.fetch(key.to_sym) }
    rescue KeyError
      raise ConfigError, "Missing #{key}"
    end

    def self.fetch_optional(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_sym]
    end

    def self.fetch_string(hash, key)
      value = fetch_value(hash, key)
      raise ConfigError, "#{key} must be a string" unless value.is_a?(String)

      value
    end
  end

  class PresetDocument
    attr_reader :presets

    def self.load_file(path)
      load_yaml(File.read(path), source: path)
    rescue SystemCallError => error
      raise ConfigError, "Cannot read preset document #{path}: #{error.message}"
    end

    def self.load_yaml(yaml, source: "<inline>")
      data = YAML.safe_load(yaml, permitted_classes: [], aliases: false)
      new(data, source: source)
    rescue Psych::Exception => error
      raise ConfigError, "Invalid YAML in #{source}: #{error.message}"
    end

    def initialize(data, source:)
      raise ConfigError, "Preset document must be a mapping" unless data.is_a?(Hash)

      preset_data = data["presets"]
      raise ConfigError, "Preset document must define presets" unless preset_data.is_a?(Hash) && preset_data.any?

      @presets = preset_data.each_with_object({}) do |(name, config), result|
        raise ConfigError, "Preset #{name} must be a mapping" unless config.is_a?(Hash)

        layout_data = config["layout"] || config
        result[name.to_s] = Preset.new(name: name.to_s, layout: PaneLayout.from_hash(layout_data))
      end
    end
  end

  class LayoutDocument
    def self.load_file(path)
      load_yaml(File.read(path), source: path)
    rescue SystemCallError => error
      raise ConfigError, "Cannot read layout document #{path}: #{error.message}"
    end

    def self.load_yaml(yaml, source: "<inline>")
      data = YAML.safe_load(yaml, permitted_classes: [], aliases: false)
      PaneLayout.from_hash(data)
    rescue Psych::Exception => error
      raise ConfigError, "Invalid YAML in #{source}: #{error.message}"
    end
  end

  module PresetLookup
    module_function

    LOCAL_FILE = ".tmux-layout.yml"
    GLOBAL_FILE = File.join(Dir.home, ".config", "tmux-workspace", "layouts.yml")

    def find(explicit_file: nil, launch_directory: Dir.pwd)
      return File.expand_path(explicit_file) if explicit_file

      nearest_local(launch_directory) || GLOBAL_FILE
    end

    def nearest_local(start)
      current = File.expand_path(start)

      loop do
        candidate = File.join(current, LOCAL_FILE)
        return candidate if File.file?(candidate)

        parent = File.dirname(current)
        return nil if parent == current

        current = parent
      end
    end
  end

  module PresetSelection
    module_function

    def select(document, name = nil)
      return named(document, name) if name
      return document.presets["default"] if document.presets.key?("default")
      return document.presets.values.first if document.presets.length == 1

      raise ConfigError, "Multiple presets found; pass --preset <name>"
    end

    def named(document, name)
      preset = document.presets[name.to_s]
      raise ConfigError, "Unknown preset #{name.inspect}" unless preset

      preset
    end
  end

  class TmuxPlan
    attr_reader :steps

    def self.build(session:, start_directory:, layout:, window_name: nil)
      new.tap do |plan|
        plan.add(:new_session, session, start_directory, window_name)
        plan.materialize(layout, "#{session}:0.0", start_directory)
        plan.add(:select_pane, "#{session}:0.0")
      end
    end

    def self.append_window(session:, window_name:, start_directory:, layout:)
      target = "#{session}:append.0"
      new.tap do |plan|
        plan.add(:new_window, session, target, window_name, start_directory)
        plan.materialize(layout, target, start_directory)
        plan.add(:select_pane, target)
      end
    end

    def initialize
      @steps = []
      @next_pane_index = 1
    end

    def add(*step)
      @steps << step
    end

    def materialize(layout, target, inherited_cwd)
      cwd = resolve_cwd(inherited_cwd, layout.cwd)

      if layout.leaf?
        if layout.command && !layout.command.to_s.empty?
          add(:send_command, target, layout.command, layout.title, cwd)
        else
          add(:open_shell, target, layout.title, cwd)
        end
        return
      end

      targets = [target]

      layout.panes[1..-1].each_with_index do |pane, index|
        target_index = @next_pane_index
        @next_pane_index += 1
        new_target = target.sub(/\.\d+\z/, ".#{target_index}")
        size = split_percentage(layout.ratio, index + 1)
        add(:split_window, target, new_target, layout.direction_flag, resolve_cwd(cwd, pane.cwd), size)
        targets << new_target
      end

      layout.panes.zip(targets).each do |pane, pane_target|
        materialize(pane, pane_target, cwd)
      end
    end

    def execute(tmux: Tmux.new)
      steps.each { |step| tmux.apply(step) }
    end

    private

    def resolve_cwd(base, child)
      return File.expand_path(base) if child.nil? || child.to_s.empty?

      File.expand_path(child, base)
    end

    def split_percentage(ratio, pane_index)
      return nil unless ratio

      remaining = ratio[0] + ratio[pane_index..-1].inject(0) { |sum, value| sum + value.to_f }
      ((ratio[pane_index].to_f / remaining) * 100).round
    end
  end

  class Tmux
    def initialize
      @pane_targets = {}
    end

    def session_exists?(name)
      system("tmux", "has-session", "-t", name, out: File::NULL, err: File::NULL)
    end

    def kill_session(name)
      run!("tmux", "kill-session", "-t", name)
    end

    def enter_session(name)
      if ENV["TMUX"] && !ENV["TMUX"].empty?
        run_interactive!("tmux", "switch-client", "-t", name)
      else
        run_interactive!("tmux", "attach-session", "-t", name)
      end
    end

    def set_terminal_title(session, title)
      run!("tmux", "set-option", "-t", session, "set-titles", "on")
      run!("tmux", "set-option", "-t", session, "set-titles-string", TerminalTitle.sanitize(title))
    rescue TmuxError
      nil
    end

    def apply(step)
      type, *args = step
      case type
      when :new_session
        session, cwd, window_name = args
        argv = ["tmux", "new-session", "-d", "-P", "-F", '#{pane_id}', "-s", session, "-c", cwd]
        argv.concat(["-n", window_name]) if window_name && !window_name.empty?
        pane_id = run!(*argv).strip
        @pane_targets["#{session}:0.0"] = pane_id
      when :new_window
        session, target, window_name, cwd = args
        argv = ["tmux", "new-window", "-d", "-P", "-F", '#{pane_id}', "-t", session, "-c", cwd]
        argv.concat(["-n", window_name]) if window_name && !window_name.empty?
        @pane_targets[target] = run!(*argv).strip
      when :split_window
        target, new_target, flag, cwd, size = args
        argv = ["tmux", "split-window", "-P", "-F", '#{pane_id}', "-t", pane_target(target), flag, "-c", cwd]
        argv.concat(["-p", size.to_s]) if size
        @pane_targets[new_target] = run!(*argv).strip
      when :send_command
        target, command, title, cwd = args
        actual_target = pane_target(target)
        rename_pane(actual_target, title) if title && !title.empty?
        run!("tmux", "send-keys", "-t", actual_target, "cd #{Shellwords.escape(cwd)} && #{command}; exec #{Shellwords.escape(shell)}", "C-m")
      when :open_shell
        target, title, cwd = args
        actual_target = pane_target(target)
        rename_pane(actual_target, title) if title && !title.empty?
        run!("tmux", "send-keys", "-t", actual_target, "cd #{Shellwords.escape(cwd)} && exec #{Shellwords.escape(shell)}", "C-m")
      when :select_pane
        target = args.first
        run!("tmux", "select-pane", "-t", pane_target(target))
      else
        raise TmuxError, "Unknown tmux plan step: #{type}"
      end
    end

    private

    def rename_pane(target, title)
      run!("tmux", "select-pane", "-t", target, "-T", title)
    end

    def pane_target(target)
      @pane_targets.fetch(target, target)
    end

    def shell
      ENV["SHELL"] || Etc.getpwuid.shell || "/bin/sh"
    end

    def run!(*argv)
      output, error, status = Open3.capture3(*argv)
      raise TmuxError, "Command failed: #{argv.shelljoin}\n#{error}" unless status.success?

      output
    end

    def run_interactive!(*argv)
      return if system(*argv)

      raise TmuxError, "Command failed: #{argv.shelljoin}"
    end
  end

  class CLI
    def self.run(argv, env: ENV, out: $stdout, err: $stderr, stdin: $stdin)
      new(argv, env: env, out: out, err: err, stdin: stdin).run
    end

    def initialize(argv, env:, out:, err:, stdin: $stdin, tmux: Tmux.new, git: Git.new)
      @argv = argv.dup
      @out = out
      @err = err
      @stdin = stdin
      @tmux = tmux
      @git = git
      @env = env
      @options = {
        launch_directory: Dir.pwd,
        attach: true,
        recreate: false,
        append_window: false
      }
    end

    def run
      parse!
      launch_directory = File.expand_path(@options[:launch_directory])
      return list_presets(launch_directory) if @options[:list]

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

      if @tmux.session_exists?(identity.tmux_name)
        if @options[:recreate]
          @tmux.kill_session(identity.tmux_name)
        else
          @out.puts "Attaching existing session #{identity.tmux_name}"
          prepare_terminal_title(identity)
          enter_or_print(identity.tmux_name)
          return 0
        end
      end

      selected = selected_layout(launch_directory)
      TmuxPlan.build(session: identity.tmux_name, start_directory: launch_directory, layout: selected.layout).execute(tmux: @tmux)
      prepare_terminal_title(identity)
      enter_or_print(identity.tmux_name)
      0
    rescue Error, OptionParser::ParseError => error
      @err.puts "tms: #{error.message}"
      1
    end

    private

    def parse!
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tms [options]"
        opts.on("-p", "--preset NAME", "Launch a named preset") { |value| @options[:preset] = value }
        opts.on("-f", "--file PATH", "Use a preset document") { |value| @options[:file] = value }
        opts.on("-l", "--layout PATH", "Use a complete one-off layout document") { |value| @options[:layout] = value }
        opts.on("-L", "--list", "List available presets") { @options[:list] = true }
        opts.on("--verbose", "Show pane structure when listing") { @options[:verbose] = true }
        opts.on("-A", "--append-window", "Append a window to the workspace session") { @options[:append_window] = true }
        opts.on("-C", "--directory PATH", "Launch as if invoked from PATH") { |value| @options[:launch_directory] = value }
        opts.on("-R", "--recreate", "Kill and recreate an existing session") { @options[:recreate] = true }
        opts.on("--no-attach", "Create or reuse the session without entering it") { @options[:attach] = false }
        opts.on("-h", "--help", "Show help") do
          @out.puts opts
          exit 0
        end
      end

      parser.parse!(@argv)
      raise ConfigError, "--list cannot be combined with --layout" if @options[:list] && @options[:layout]
      raise ConfigError, "--list cannot be combined with --recreate" if @options[:list] && @options[:recreate]
      raise ConfigError, "--list cannot be combined with --append-window" if @options[:list] && @options[:append_window]
      raise ConfigError, "--layout cannot be combined with --preset or --file" if @options[:layout] && (@options[:preset] || @options[:file])
      raise ConfigError, "--append-window cannot be combined with --recreate" if @options[:append_window] && @options[:recreate]
      raise ConfigError, "Unexpected arguments: #{@argv.join(" ")}" unless @argv.empty?
    end

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

    def list_presets(launch_directory)
      preset_path = PresetLookup.find(explicit_file: @options[:file], launch_directory: launch_directory)

      unless File.file?(preset_path)
        @err.puts "No preset file found."
        @err.puts "Run 'make config' to create one at ~/.config/tmux-workspace/layouts.yml"
        return 0
      end

      document = PresetDocument.load_file(preset_path)

      if @options[:preset]
        print_preset(PresetSelection.named(document, @options[:preset]))
      else
        @out.puts "Available presets (from #{preset_path}):"
        document.presets.each_value { |preset| print_preset(preset) }
      end

      0
    end

    def print_preset(preset)
      unless @options[:verbose]
        @out.puts "  #{preset.name}"
        return
      end

      @out.puts "#{preset.name}:"
      print_layout_node(preset.layout, "  ")
    end

    def print_layout_node(layout, prefix, connector = nil, last = true)
      branch_prefix = connector ? "#{prefix}#{connector}" : prefix
      @out.puts "#{branch_prefix}#{layout_label(layout)}"
      return if layout.leaf?

      child_prefix = if connector
                       "#{prefix}#{last ? "    " : "│   "}"
                     else
                       prefix
                     end
      layout.panes.each_with_index do |pane, index|
        child_last = index == layout.panes.length - 1
        print_layout_node(pane, child_prefix, child_last ? "└── " : "├── ", child_last)
      end
    end

    def layout_label(layout)
      if layout.branch?
        label = layout.split
        label = "#{label} [#{layout.ratio.join(", ")}]" if layout.ratio
        return label
      end

      title = layout.title.to_s unless layout.title.nil? || layout.title.to_s.empty?
      command = layout.command.to_s unless layout.command.nil? || layout.command.to_s.empty?
      return "#{title}: #{command}" if title && command

      title || command || "shell"
    end

    def layout_window_name(path)
      basename = File.basename(path.to_s, File.extname(path.to_s))
      basename.empty? ? "layout" : basename
    end

    def enter_or_print(name)
      return unless @options[:attach]

      if terminal?
        @tmux.enter_session(name)
      else
        @out.puts "Session #{name} is ready."
        @out.puts "Attach with: tmux attach-session -t #{Shellwords.escape(name)}"
      end
    end

    def prepare_terminal_title(identity)
      @tmux.set_terminal_title(identity.tmux_name, identity.display_name) if @tmux.respond_to?(:set_terminal_title)
      return unless @options[:attach] && terminal? && !inside_tmux?

      @out.print TerminalTitle.sequence(identity.display_name)
      @out.flush if @out.respond_to?(:flush)
    end

    def inside_tmux?
      @env["TMUX"] && !@env["TMUX"].empty?
    end

    def terminal?
      @stdin.respond_to?(:tty?) && @stdin.tty? && @out.respond_to?(:tty?) && @out.tty?
    end
  end
end
