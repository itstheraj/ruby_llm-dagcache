# frozen_string_literal: true

require_relative "test_helper"

class TestStore < Minitest::Test
  include StoreCase

  G = RubyLLM::DagCache

  def make_dag(kind: "task", fp: "fp1", tool_names: %w[a b])
    nodes = tool_names.each_with_index.map do |name, i|
      G::Node.new(id: "n#{i}", kind: "tool", name: name, purity: "pure", output_shape: "str")
    end
    G::DAG.new(task_kind: kind, fingerprint: fp, nodes: nodes)
  end

  def test_save_dedupes_identical_paths
    store.save_dag(make_dag)
    store.save_dag(make_dag)
    all = store.load_all
    assert_equal 1, all.size
    assert_equal 2, all.first.recordings
  end

  def test_lookup_finds_staging_with_auto_replay
    store.save_dag(make_dag)
    dag = store.lookup("task", "fp1")
    assert_equal %w[a b], dag.path
    assert_equal "staging", dag.status
  end

  def test_approved_beats_staging_and_stats_rank_paths
    id_a = store.save_dag(make_dag(tool_names: ["a"]))
    id_b = store.save_dag(make_dag(tool_names: ["b"]))
    3.times { store.record_hit(id_b) }
    assert_equal ["b"], store.lookup("task", "fp1").path
    store.approve(id_a)
    assert_equal ["a"], store.lookup("task", "fp1").path
  end

  def test_fallbacks_kill_flaky_staging_dags
    id = store.save_dag(make_dag)
    3.times { store.record_fallback(id) }
    assert_equal "dead", store.get(id).status
    assert_nil store.lookup("task", "fp1")
  end

  def test_approved_dags_survive_fallbacks
    id = store.save_dag(make_dag)
    store.approve(id)
    10.times { store.record_fallback(id) }
    refute_nil store.lookup("task", "fp1")
  end

  def test_ttl_expiry
    store.save_dag(make_dag, ttl_seconds: 0)
    assert_nil store.lookup("task", "fp1")
  end

  def test_prune_and_demote
    id_a = store.save_dag(make_dag(tool_names: ["a"]))
    store.save_dag(make_dag(tool_names: ["b"]))
    store.demote(id_a)
    assert_equal 2, store.prune(status: "staging")
    assert_empty store.load_all
  end

  def test_cassettes_are_human_readable_yaml
    store.save_dag(make_dag)
    file = Dir.glob(File.join(@dir, "*.yml")).first
    content = File.read(file)
    assert_includes content, "task_kind: task"
    assert_includes content, "- a"
  end
end
