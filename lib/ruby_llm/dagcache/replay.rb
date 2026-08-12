# frozen_string_literal: true

require "json"

module RubyLLM
  module DagCache
    # The Luigi-style worker: execute a cached DAG against new inputs.
    #
    # :verified (default) -- re-execute every tool with freshly resolved
    # arguments (real side effects, fresh data) and re-run output LLM calls.
    # Planning LLM calls are never re-run: the DAG *is* the plan. Any drift
    # raises Divergence and the caller falls back to the live agent.
    #
    # :frozen -- VCR mode. Nothing executes; recorded outputs are returned.
    module Replay
      class Divergence < StandardError; end

      # Substitute fresh upstream outputs into recorded literal arguments
      # (prompt patching): whole values, JSON forms, and changed leaves.
      module Patching
        module_function

        def replacement_pairs(recorded, fresh)
          pairs = []
          pairs << [recorded, fresh] if recorded.is_a?(String) && fresh.is_a?(String)
          begin
            pairs << [JSON.generate(recorded), JSON.generate(fresh)]
          rescue JSON::GeneratorError
            # not JSON-able; skip the JSON form
          end
          pairs << [recorded.to_s, fresh.to_s]
          leaf_pairs(recorded, fresh, pairs)
          # Bounded (non-substring) replacement makes short values safe.
          pairs.uniq.select { |old, new| old.length >= 2 && old != new }
        end

        # Pair up leaves at matching paths that changed between runs --
        # strings, and numbers like prices/temps/quantities.
        def leaf_pairs(recorded, fresh, out)
          case recorded
          when Hash
            return unless fresh.is_a?(Hash)

            recorded.each { |k, v| leaf_pairs(v, fresh[k], out) if fresh.key?(k) }
          when Array
            return unless fresh.is_a?(Array)

            recorded.zip(fresh) { |a, b| leaf_pairs(a, b, out) }
          when String
            out << [recorded, fresh] if fresh.is_a?(String) && recorded != fresh
          when Integer, Float
            out << [recorded.to_s, fresh.to_s] if fresh.is_a?(recorded.class) && recorded != fresh
          end
        end

        def patch(value, dag, outputs)
          case value
          when String
            dag.nodes.reduce(value) do |text, node|
              next text unless outputs.key?(node.id) && !node.recorded_output.nil?

              replacement_pairs(node.recorded_output, outputs[node.id]).reduce(text) do |t, (old, new)|
                t.gsub(/(?<!\w)#{Regexp.escape(old)}(?!\w)/, new)
              end
            end
          when Array then value.map { |v| patch(v, dag, outputs) }
          when Hash then value.to_h { |k, v| [k, patch(v, dag, outputs)] }
          else value
          end
        end
      end

      class Executor
        def initialize(mode = :verified)
          mode = mode.to_sym
          raise ArgumentError, "mode must be :verified or :frozen" unless %i[verified frozen].include?(mode)

          @mode = mode
        end

        def run(dag, inputs)
          outputs = {}
          dag.topo_order.each do |node|
            if node.kind == "llm_plan" || @mode == :frozen
              # The plan is what's cached; frozen mode caches outputs too.
              outputs[node.id] = node.recorded_output
              next
            end
            callable, style = callable_for(node)
            args = {}
            node.args.each do |arg_name, binding|
              args[arg_name.to_sym] =
                begin
                  Bindings.resolve(binding, inputs, outputs)
                rescue Bindings::BindingError => e
                  raise Divergence, "#{node.name}.#{arg_name}: #{e.message}"
                end
            end
            args = Patching.patch(args, dag, outputs)
            fresh =
              begin
                style == :kwargs ? callable.call(**args) : callable.call(*args.values)
              rescue Divergence
                raise
              rescue StandardError => e
                raise Divergence, "#{node.name} raised #{e.class}: #{e.message}"
              end
            unless Keys.structure(Bindings.jsonable(fresh)) == node.output_shape
              raise Divergence, "#{node.name} output shape drifted"
            end

            outputs[node.id] = fresh
          end
          outputs[dag.terminal.id]
        end

        private

        def callable_for(node)
          entry =
            case node.kind
            when "tool" then DagCache.tools[node.name]
            when "llm_output" then DagCache.llms[node.name]
            end
          raise Divergence, "no live callable registered for #{node.kind}:#{node.name}" if entry.nil?

          [entry[:callable], entry[:style]]
        end
      end
    end
  end
end
