# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

class MakefileTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_config_defaults_to_global_layout_file
    Dir.mktmpdir("tms-home") do |home|
      output, status = Open3.capture2e("make", "-n", "config", "HOME=#{home}", chdir: ROOT)

      assert status.success?, output
      assert_includes output, File.join(home, ".config", "tmux-scripts", "layouts.yml")
      refute_includes output, "cp \"#{File.join(ROOT, ".tmux-layout.example.yml")}\" \".tmux-layout.yml\""
    end
  end
end
