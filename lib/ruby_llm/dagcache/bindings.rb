# frozen_string_literal: true

module RubyLLM
  module DagCache
    # Turn recorded literal arguments into re-bindable slots, and back.
    #
    # At record time we infer the *provenance* of every tool argument:
    # straight from the agent's input? From an upstream tool's output? Or
    # did the LLM make it up (literal)? At replay time bindings resolve
    # against the *new* inputs and *fresh* upstream outputs -- which is how
    # a cached path runs on data it has never seen.
    module Bindings
      class BindingError < StandardError; end

      MAX_DEPTH = 12
      MAX_MATCHES = 8

      module_function

      # Values too generic to safely provenance-match stay literal.
      def worth_matching?(value)
        case value
        when NilClass, TrueClass, FalseClass then false
        when Numeric then value.abs >= 100
        when String then value.length >= 2
        else true
        end
      end

      def walk(root, path)
        path.reduce(root) do |cur, seg|
          case cur
          when Hash
            key = [seg, seg.to_s, (seg.to_sym if seg.respond_to?(:to_sym))].compact.find { |k| cur.key?(k) }
            raise BindingError, "missing key #{seg.inspect} in #{cur.inspect}" if key.nil?

            cur[key]
          when Array
            begin
              cur[Integer(seg)]
            rescue ArgumentError, TypeError
              raise BindingError, "missing index #{seg.inspect}"
            end
          else
            attr = seg.to_s
            if cur.instance_variable_defined?(:"@#{attr}")
              cur.instance_variable_get(:"@#{attr}")
            elsif cur.respond_to?(attr)
              cur.public_send(attr)
            else
              raise BindingError, "missing attribute #{attr.inspect} on #{cur.class}"
            end
          end
        end
      end

      # Collect paths under +root+ whose value deep-equals +value+.
      def find(value, root, base, out, depth = 0)
        return if depth > MAX_DEPTH || out.size > MAX_MATCHES

        if root.class == value.class && root == value
          out << base
          return
        end
        case root
        when Hash
          root.each { |k, v| find(value, v, base + [k.to_s], out, depth + 1) }
        when Array
          root.each_with_index { |v, i| find(value, v, base + [i], out, depth + 1) }
        else
          root.instance_variables.reject { |iv| iv.to_s.start_with?("@_") }.each do |iv|
            find(value, root.instance_variable_get(iv), base + [iv.to_s.delete_prefix("@")], out, depth + 1)
          end
        end
      end

      # Infer where a recorded argument value came from. Inputs win over
      # node outputs; earliest nodes win over later ones.
      def infer_binding(value, inputs, prior)
        return Binding.new(source: "literal", value: jsonable(value)) unless worth_matching?(value)

        found = []
        find(value, inputs, [], found)
        return Binding.new(source: "input", path: found.min_by(&:size)) if found.any?

        prior.each do |node_id, output|
          found = []
          find(value, output, [], found)
          return Binding.new(source: "node", path: [node_id] + found.min_by(&:size)) if found.any?
        end

        Binding.new(source: "literal", value: jsonable(value))
      end

      # Resolve a binding against this call's inputs and fresh outputs.
      def resolve(binding, inputs, outputs)
        case binding.source
        when "literal" then binding.value
        when "input"
          walk(inputs, binding.path)
        when "node"
          node_id = binding.path.first
          raise BindingError, "node binding references unavailable node #{binding.path.inspect}" unless outputs.key?(node_id)

          walk(outputs[node_id], binding.path[1..])
        else
          raise BindingError, "unknown binding source #{binding.source.inspect}"
        end
      rescue BindingError => e
        raise BindingError, "#{binding.source} binding #{binding.path.inspect}: #{e.message}"
      end

      # Best-effort conversion to a YAML/JSON-serializable value.
      def jsonable(value)
        case value
        when NilClass, TrueClass, FalseClass, Numeric, String then value
        when Hash then value.to_h { |k, v| [k.to_s, jsonable(v)] }
        when Array then value.map { |v| jsonable(v) }
        else
          ivars = value.instance_variables.reject { |iv| iv.to_s.start_with?("@_") }
          if ivars.any?
            { "__class__" => value.class.name }.merge(
              ivars.to_h { |iv| [iv.to_s.delete_prefix("@"), jsonable(value.instance_variable_get(iv))] }
            )
          else
            value.inspect
          end
        end
      end
    end
  end
end
