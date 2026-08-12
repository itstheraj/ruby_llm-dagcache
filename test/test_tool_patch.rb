# frozen_string_literal: true

require_relative "test_helper"

# The ToolPatch: RubyLLM::Tool subclasses are recorded automatically while
# inside a watched agent call -- no DSL needed on the RubyLLM side.
class TestToolPatch < Minitest::Test
  include StoreCase

  DC = RubyLLM::DagCache

  class FakeWeatherTool < RubyLLM::Tool
    def self.calls
      @calls ||= []
    end

    def self.temp
      @temp ||= 21
    end

    class << self
      attr_writer :temp
    end

    def execute(latitude:, longitude:)
      self.class.calls << [latitude, longitude]
      { "temp" => self.class.temp }
    end
  end

  class FakeWeatherAgent
    def initialize(tool, draft)
      @tool = tool
      @draft = draft
    end

    def ask(city)
      data = @tool.execute(latitude: 52.5, longitude: 13.4)
      @draft.call("It is #{data['temp']} degrees")
    end
  end

  def setup
    super
    FakeWeatherTool.calls.clear
    FakeWeatherTool.temp = 21
    @draft_calls = []
    draft_calls = @draft_calls
    draft = DC.llm("wx_draft") { |prompt| draft_calls << prompt; "text: #{prompt}" }
    @agent = DC.watch(FakeWeatherAgent.new(FakeWeatherTool.new, draft), kind: "wx")
  end

  def test_tool_execute_recorded_and_replayed
    assert_equal "text: It is 21 degrees", @agent.ask("Berlin")
    assert_equal 1, FakeWeatherTool.calls.size
    assert_equal 1, @draft_calls.size

    FakeWeatherTool.temp = 30 # the world moved on
    assert_equal "text: It is 30 degrees", @agent.ask("Paris")
    assert_equal 2, FakeWeatherTool.calls.size # tool re-executed (verified)
    assert_equal 2, @draft_calls.size          # output LLM re-run
    assert_equal "It is 30 degrees", @draft_calls.last # prompt patched fresh

    assert_equal 1, store.load_all.first.hits
  end

  def test_frozen_mode_returns_recorded
    @agent.ask("Berlin")
    DC.configure { |c| c.replay_mode = :frozen }
    FakeWeatherTool.temp = 30
    assert_equal "text: It is 21 degrees", @agent.ask("Paris")
    assert_equal 1, FakeWeatherTool.calls.size
  end

  def test_outside_watch_calls_pass_through_unrecorded
    result = FakeWeatherTool.new.execute(latitude: 1.0, longitude: 2.0)
    assert_equal({ "temp" => 21 }, result)
    assert_empty store.load_all
  end
end
