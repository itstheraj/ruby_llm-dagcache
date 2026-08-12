# frozen_string_literal: true

module RubyLLM
  module DagCache
    # Accumulates nodes for one agent run. Thread-local, so concurrent
    # agents each get their own recording; the observed code runs unmodified.
    class Recorder
      attr_reader :task_kind, :fingerprint, :inputs, :nodes

      def initialize(task_kind:, fingerprint:, inputs:)
        @task_kind = task_kind
        @fingerprint = fingerprint
        @inputs = inputs
        @nodes = []
        @live_outputs = {}
      end

      def self.current
        Thread.current[:dagcache_recorder]
      end

      def record
        Thread.current[:dagcache_recorder] = self
        yield
      ensure
        Thread.current[:dagcache_recorder] = nil
      end

      def add_node(kind:, name:, purity:, args_live:, result_live:, duration_ms: 0.0)
        nid = "n#{@nodes.size}"
        recorded = Bindings.jsonable(result_live)
        prior = @nodes.map { |n| [n.id, @live_outputs[n.id]] }
        bindings = (args_live || {}).to_h do |k, v|
          [k.to_s, Bindings.infer_binding(v, @inputs, prior)]
        end
        @nodes << Node.new(
          id: nid, kind: kind, name: name, purity: purity,
          args: bindings, recorded_output: recorded,
          output_shape: Keys.structure(recorded), duration_ms: duration_ms
        )
        @live_outputs[nid] = result_live
      end

      # Compute Luigi-style +requires+ edges and return the DAG. Data deps
      # come from node-output bindings; effectful and LLM nodes also depend
      # on the previous node, preserving side-effect order.
      def finalize
        @nodes.each_with_index do |node, i|
          deps = node.args.values.select { |b| b.source == "node" }.map { |b| b.path.first }.uniq
          deps << @nodes[i - 1].id if i.positive? && node.purity != "pure"
          node.requires = deps.sort_by { |d| d[1..].to_i }
        end
        DAG.new(task_kind: @task_kind, fingerprint: @fingerprint, nodes: @nodes)
      end
    end
  end
end
