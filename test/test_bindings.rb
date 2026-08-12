# frozen_string_literal: true

require_relative "test_helper"

class TestBindings < Minitest::Test
  B = RubyLLM::DagCache::Bindings
  Binding = RubyLLM::DagCache::Binding

  def test_infer_input_binding_nested
    inputs = { "ticket" => { "id" => "T-1", "title" => "broken widget" } }
    b = B.infer_binding("broken widget", inputs, [])
    assert_equal "input", b.source
    assert_equal %w[ticket title], b.path
  end

  def test_infer_input_binding_through_symbol_keys
    inputs = { ticket: { title: "broken widget" } }
    b = B.infer_binding("broken widget", inputs, [])
    assert_equal "input", b.source
    assert_equal %w[ticket title], b.path
    assert_equal "fresh", B.resolve(b, { ticket: { title: "fresh" } }, {})
  end

  def test_infer_node_binding
    prior = [["n0", { "order_id" => "O-9", "status" => "shipped" }]]
    b = B.infer_binding("O-9", { "ticket" => { "x" => "unrelated" } }, prior)
    assert_equal "node", b.source
    assert_equal ["n0", "order_id"], b.path
  end

  def test_generic_values_stay_literal
    assert_equal "literal", B.infer_binding(true, { "flag" => true }, []).source
    assert_equal "literal", B.infer_binding(5, { "count" => 5 }, []).source
    assert_equal "literal", B.infer_binding("x", { "s" => "x" }, []).source
    assert_equal "literal", B.infer_binding("never seen before", { "s" => "else" }, []).source
  end

  def test_input_wins_over_node_output
    prior = [["n0", { "v" => "shared-value" }]]
    inputs = { "a" => { "v" => "shared-value" } }
    assert_equal "input", B.infer_binding("shared-value", inputs, prior).source
  end

  def test_resolve_node_binding_uses_fresh_output
    b = Binding.new(source: "node", path: ["n0", "order_id"])
    assert_equal "O-new", B.resolve(b, {}, { "n0" => { "order_id" => "O-new" } })
  end

  def test_resolve_failures_raise
    assert_raises(B::BindingError) { B.resolve(Binding.new(source: "input", path: ["missing"]), {}, {}) }
    assert_raises(B::BindingError) { B.resolve(Binding.new(source: "node", path: %w[n9 x]), {}, {}) }
  end
end
