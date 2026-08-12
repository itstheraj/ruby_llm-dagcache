# frozen_string_literal: true

require_relative "test_helper"

class TestGraph < Minitest::Test
  G = RubyLLM::DagCache

  def make_node(id, name, kind: "tool", purity: "pure", requires: [])
    G::Node.new(id: id, kind: kind, name: name, purity: purity,
                recorded_output: "out-#{id}", output_shape: "str", requires: requires)
  end

  def test_serde_roundtrip
    n0 = make_node("n0", "search")
    n1 = make_node("n1", "fetch", requires: ["n0"])
    n1.args["order_id"] = G::Binding.new(source: "node", path: ["n0", "order_id"])
    dag = G::DAG.new(task_kind: "k", fingerprint: "fp", nodes: [n0, n1])

    back = G::DAG.from_h(dag.to_h)
    assert_equal "k", back.task_kind
    assert_equal ["n0", "order_id"], back.nodes[1].args["order_id"].path
    assert_equal ["n0"], back.nodes[1].requires
  end

  def test_path_excludes_llm_nodes
    nodes = [
      make_node("n0", "search"),
      make_node("n1", "draft", kind: "llm_output", purity: "llm"),
      make_node("n2", "send")
    ]
    dag = G::DAG.new(task_kind: "k", fingerprint: "fp", nodes: nodes)
    assert_equal %w[search send], dag.path
    assert_equal "n2", dag.terminal.id
  end

  def test_topo_order_respects_dependencies
    nodes = [
      make_node("n0", "a"),
      make_node("n1", "b", requires: ["n2"]),
      make_node("n2", "c")
    ]
    order = G::DAG.new(task_kind: "k", fingerprint: "fp", nodes: nodes).topo_order.map(&:id)
    assert order.index("n2") < order.index("n1")
  end

  def test_topo_order_detects_cycles
    nodes = [
      make_node("n0", "a", requires: ["n1"]),
      make_node("n1", "b", requires: ["n0"])
    ]
    assert_raises(RuntimeError) do
      G::DAG.new(task_kind: "k", fingerprint: "fp", nodes: nodes).topo_order
    end
  end
end
