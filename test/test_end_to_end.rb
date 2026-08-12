# frozen_string_literal: true

require_relative "test_helper"

# End-to-end: record an agent run, replay it on new inputs with zero LLM
# planning calls, patch fresh data into literals, fall back on drift.
class TestEndToEnd < Minitest::Test
  include StoreCase

  DC = RubyLLM::DagCache

  class FakeSupportAgent
    def initialize(plan:, search:, fetch:, send:, draft:)
      @plan = plan
      @search = search
      @fetch = fetch
      @send = send
      @draft = draft
    end

    def ask(ticket)
      @plan.call("handle #{ticket['title']}")
      article = @search.call(query: ticket["title"])
      order = @fetch.call(order_id: ticket["order_id"])
      @send.call(ticket_id: ticket["id"], body: "see #{article}")
      status = order.is_a?(Hash) ? order["status"] : "unknown"
      @draft.call("article=#{article}; status=#{status}")
    end
  end

  def setup
    super
    @calls = Hash.new(0)
    @seen = Hash.new { |h, k| h[k] = [] }
    @world = { status: "shipped", fetch_shape: :hash }
    calls = @calls
    seen = @seen
    world = @world

    search = DC.tool("rb_search", pure: true) do |query:|
      calls[:search] += 1
      seen[:search] << query
      "kb-article about #{query}"
    end
    fetch = DC.tool("rb_fetch", pure: true) do |order_id:|
      calls[:fetch] += 1
      seen[:fetch] << order_id
      world[:fetch_shape] == :array ? ["unexpected"] : { "order_id" => order_id, "status" => world[:status] }
    end
    send = DC.tool("rb_send", pure: false) do |ticket_id:, body:|
      calls[:send] += 1
      seen[:send] << [ticket_id, body]
      "sent:#{ticket_id}"
    end
    plan = DC.llm("rb_plan", planning: true) do |prompt|
      calls[:plan] += 1
      "search -> fetch -> send -> draft (#{prompt})"
    end
    draft = DC.llm("rb_draft") do |prompt|
      calls[:draft] += 1
      "reply: #{prompt}"
    end

    agent = FakeSupportAgent.new(plan: plan, search: search, fetch: fetch, send: send, draft: draft)
    @agent = DC.watch(agent, kind: "rb_ticket")

    @t1 = { "id" => "T-100", "title" => "where is my order", "order_id" => "O-100" }
    @t2 = { "id" => "T-200", "title" => "package never arrived", "order_id" => "O-200" }
  end

  def test_record_then_verified_replay
    r1 = @agent.ask(@t1)
    assert_equal "reply: article=kb-article about where is my order; status=shipped", r1
    assert_equal 1, @calls[:plan]

    @world[:status] = "delivered" # the world moved on
    before = @calls.dup
    r2 = @agent.ask(@t2)

    # planning LLM never ran; everything else re-executed fresh
    assert_equal before[:plan], @calls[:plan]
    assert_equal before[:search] + 1, @calls[:search]
    assert_equal before[:fetch] + 1, @calls[:fetch]
    assert_equal before[:send] + 1, @calls[:send]
    assert_equal before[:draft] + 1, @calls[:draft]

    # bindings resolved against the NEW ticket
    assert_equal "package never arrived", @seen[:search].last
    assert_equal "O-200", @seen[:fetch].last
    assert_equal "T-200", @seen[:send].last[0]
    assert_includes @seen[:send].last[1], "package never arrived" # patched literal

    assert_equal "reply: article=kb-article about package never arrived; status=delivered", r2

    dag = store.load_all.first
    assert_equal 1, dag.hits
    assert_equal 0, dag.fallbacks
  end

  def test_frozen_mode_executes_nothing
    r1 = @agent.ask(@t1)
    DC.configure { |c| c.replay_mode = :frozen }
    before = @calls.dup
    r2 = @agent.ask(@t2)
    assert_equal before, @calls
    assert_equal r1, r2
  end

  def test_drift_falls_back_to_live_agent
    @agent.ask(@t1)
    @world[:fetch_shape] = :array # API changed under us
    before = @calls.dup
    r3 = @agent.ask(@t2)

    assert_equal before[:plan] + 1, @calls[:plan]
    assert_equal 1, store.load_all.first.fallbacks
    assert r3.start_with?("reply: ")
  end

  def test_watch_key_separates_same_shaped_tasks
    refund = DC.tool("rb_refund", pure: false) { |target:| "refunded:#{target}" }
    weather = DC.tool("rb_weather", pure: true) { |target:| "sunny in #{target}" }

    router = Object.new
    router.define_singleton_method(:initialize) { |*| }
    router.instance_variable_set(:@refund, refund)
    router.instance_variable_set(:@weather, weather)
    router.define_singleton_method(:ask) do |task|
      task["category"] == "refund" ? @refund.call(target: task["target"]) : @weather.call(target: task["target"])
    end

    watched = DC.watch(router, kind: "rb_router", key: ->(task) { task["category"] })
    assert_equal "refunded:O-1", watched.ask({ "category" => "refund", "target" => "O-1" })
    assert_equal "sunny in Berlin", watched.ask({ "category" => "weather", "target" => "Berlin" })

    assert_equal 2, store.load_all.size
    paths = store.load_all.map(&:path)
    assert_includes paths, ["rb_refund"]
    assert_includes paths, ["rb_weather"]
  end
end
