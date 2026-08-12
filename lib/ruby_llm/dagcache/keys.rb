# frozen_string_literal: true

require "digest"
require "json"

module RubyLLM
  module DagCache
    # Task identity: structural fingerprints and path keys.
    #
    # Cache matching is deliberately *not* about argument values. Two calls
    # are "the same task" when they hit the same entrypoint with inputs of
    # the same *shape* (types and keys, never values). A cached solution is
    # identified by its chain of tool names -- the path.
    module Keys
      module_function

      # Recursive structural fingerprint of a value: types + hash keys only.
      def structure(value)
        case value
        when NilClass then "none"
        when TrueClass, FalseClass then "bool"
        when Integer then "int"
        when Float then "float"
        when String then "str"
        when Hash
          { "dict" => value.map { |k, v| [k.to_s, structure(v)] }.sort_by(&:first).to_h }
        when Array
          return { "list" => ["empty"] } if value.empty?

          { "list" => value.map { |v| JSON.generate(structure(v)) }.uniq.sort }
        else
          ivars = value.instance_variables.reject { |v| v.to_s.start_with?("@_") }
          if ivars.any?
            attrs = ivars.sort.to_h { |iv| [iv.to_s.delete_prefix("@"), structure(value.instance_variable_get(iv))] }
            { "obj" => value.class.name, "attrs" => attrs }
          else
            "other:#{value.class.name}"
          end
        end
      end

      # Stable hash of the *shape* of the call's arguments. +extra+ (from
      # watch's key:) is mixed in by value to keep same-shaped but
      # semantically different tasks apart.
      def fingerprint(inputs, extra: nil)
        shapes = inputs.map { |k, v| [k.to_s, structure(v)] }.sort_by(&:first).to_h
        payload = JSON.generate({ "shapes" => shapes, "key" => extra })
        Digest::SHA256.hexdigest(payload)[0, 16]
      end

      # Stable hash of a tool chain, e.g. "search_kb > fetch_order".
      def path_key(tool_names)
        Digest::SHA256.hexdigest(tool_names.join(">"))[0, 16]
      end
    end
  end
end
