# frozen_string_literal: true

module RubyLLM
  module DagCache
    # How to obtain one argument value at replay time.
    #   source "input":   walk the agent's call arguments along +path+
    #   source "node":    walk a prior node's (fresh) output; path[0] is the
    #                     upstream node id
    #   source "literal": the LLM synthesized this; reuse recorded +value+
    class Binding
      attr_accessor :source, :path, :value

      def initialize(source:, path: [], value: nil)
        @source = source
        @path = path
        @value = value
      end

      def to_h
        { "source" => @source, "path" => @path, "value" => @value }
      end

      def self.from_h(hash)
        new(source: hash["source"], path: hash["path"] || [], value: hash["value"])
      end
    end

    # One step of a recorded run. Luigi-flavored: +requires+ lists upstream
    # node ids, +recorded_output+ is the Luigi "output" that lets frozen
    # replay skip execution.
    class Node
      attr_accessor :id, :kind, :name, :purity, :args, :recorded_output,
                    :output_shape, :requires, :duration_ms

      def initialize(id:, kind:, name:, purity:, args: {}, recorded_output: nil,
                     output_shape: nil, requires: [], duration_ms: 0.0)
        @id = id
        @kind = kind # "tool" | "llm_plan" | "llm_output"
        @name = name
        @purity = purity # "pure" | "effectful" | "llm"
        @args = args # String name => Binding
        @recorded_output = recorded_output
        @output_shape = output_shape
        @requires = requires
        @duration_ms = duration_ms
      end

      def to_h
        {
          "id" => @id, "kind" => @kind, "name" => @name, "purity" => @purity,
          "args" => @args.transform_values(&:to_h),
          "recorded_output" => @recorded_output, "output_shape" => @output_shape,
          "requires" => @requires, "duration_ms" => @duration_ms
        }
      end

      def self.from_h(hash)
        new(
          id: hash["id"], kind: hash["kind"], name: hash["name"], purity: hash["purity"],
          args: (hash["args"] || {}).transform_values { |v| Binding.from_h(v) },
          recorded_output: hash["recorded_output"], output_shape: hash["output_shape"],
          requires: hash["requires"] || [], duration_ms: hash["duration_ms"] || 0.0
        )
      end
    end

    # The cached artifact: an ordered DAG of nodes. +id+/+status+/stats are
    # store-managed metadata, not part of the artifact.
    class DAG
      attr_accessor :task_kind, :fingerprint, :nodes, :id, :status,
                    :recordings, :hits, :fallbacks, :created_at, :ttl_seconds

      def initialize(task_kind:, fingerprint:, nodes: [])
        @task_kind = task_kind
        @fingerprint = fingerprint
        @nodes = nodes
        @id = nil
        @status = "staging" # staging | approved | dead
        @recordings = 1
        @hits = 0
        @fallbacks = 0
      end

      # The canonical tool chain -- this is what we cache *on*.
      def path
        @nodes.select { |n| n.kind == "tool" }.map(&:name)
      end

      def path_key
        Keys.path_key(path)
      end

      def terminal
        @nodes.last or raise "DAG has no nodes"
      end

      # Kahn's algorithm with original index as tiebreak (stable order).
      def topo_order
        index = @nodes.each_with_index.to_h { |n, i| [n.id, i] }
        indegree = @nodes.to_h { |n| [n.id, 0] }
        downstream = @nodes.to_h { |n| [n.id, []] }
        @nodes.each do |n|
          n.requires.each do |dep|
            raise "node #{n.id} requires unknown node #{dep}" unless indegree.key?(dep)

            indegree[n.id] += 1
            downstream[dep] << n.id
          end
        end
        ready = indegree.select { |_, d| d.zero? }.keys.sort_by { |id| index[id] }
        by_id = @nodes.to_h { |n| [n.id, n] }
        order = []
        until ready.empty?
          nid = ready.shift
          order << by_id[nid]
          downstream[nid].each do |nxt|
            indegree[nxt] -= 1
            ready << nxt if indegree[nxt].zero?
          end
          ready.sort_by! { |id| index[id] }
        end
        raise "DAG contains a cycle" if order.size != @nodes.size

        order
      end

      def to_h
        {
          "task_kind" => @task_kind, "fingerprint" => @fingerprint,
          "path" => path, "nodes" => @nodes.map(&:to_h)
        }
      end

      def self.from_h(hash)
        new(
          task_kind: hash["task_kind"], fingerprint: hash["fingerprint"],
          nodes: (hash["nodes"] || []).map { |n| Node.from_h(n) }
        )
      end
    end
  end
end
