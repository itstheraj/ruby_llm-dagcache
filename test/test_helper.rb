# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "tmpdir"

# Fake RubyLLM::Tool so ToolPatch has something to prepend to. The real gem
# is not needed to test dagcache itself -- the patch is duck-typed.
module RubyLLM
  class Tool
    def execute(**)
      raise NotImplementedError
    end
  end
end

require "minitest/autorun"
require "ruby_llm/dagcache"

# Per-test isolated YAML store + fresh configuration.
module StoreCase
  def setup
    RubyLLM::DagCache.reset_configuration!
    @dir = Dir.mktmpdir
    RubyLLM::DagCache.configure { |c| c.store_path = @dir }
  end

  def teardown
    FileUtils.remove_entry(@dir)
    RubyLLM::DagCache.reset_configuration!
  end

  def store
    RubyLLM::DagCache::Store.new(@dir)
  end
end
