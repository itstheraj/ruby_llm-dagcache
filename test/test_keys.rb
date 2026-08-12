# frozen_string_literal: true

require_relative "test_helper"

class TestKeys < Minitest::Test
  K = RubyLLM::DagCache::Keys

  def test_structure_ignores_values
    a = { "id" => "T-1", "title" => "broken", "tags" => %w[a b] }
    b = { "id" => "T-99", "title" => "different", "tags" => %w[x] }
    assert_equal K.structure(a), K.structure(b)
  end

  def test_structure_treats_symbol_and_string_keys_alike
    assert_equal K.structure({ id: "T-1" }), K.structure({ "id" => "T-2" })
  end

  def test_structure_distinguishes_shapes
    refute_equal K.structure({ "a" => 1 }), K.structure({ "a" => "1" })
    refute_equal K.structure({ "a" => 1 }), K.structure({ "a" => 1, "b" => 2 })
    refute_equal K.structure([1]), K.structure({ "0" => 1 })
    refute_equal K.structure(nil), K.structure(false)
  end

  def test_fingerprint_stable_and_value_independent
    i1 = { "ticket" => { "id" => "T-1", "n" => 3 } }
    i2 = { "ticket" => { "id" => "T-2", "n" => 400 } }
    assert_equal K.fingerprint(i1), K.fingerprint(i2)
    refute_equal K.fingerprint(i1), K.fingerprint({ "ticket" => { "id" => "T-2" } })
  end

  def test_fingerprint_extra_separates_same_shape
    inputs = { "task" => { "target" => "x" } }
    refute_equal K.fingerprint(inputs, extra: "refund"), K.fingerprint(inputs, extra: "weather")
  end

  def test_path_key
    assert_equal K.path_key(%w[a b]), K.path_key(%w[a b])
    refute_equal K.path_key(%w[a b]), K.path_key(%w[b a])
  end
end
