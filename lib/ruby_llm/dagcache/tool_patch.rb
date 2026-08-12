# frozen_string_literal: true

module RubyLLM
  module DagCache
    # Prepended onto each RubyLLM::Tool subclass: while a recording is
    # active, every tool execution becomes a node in the DAG and the tool
    # instance is registered so verified replay can re-execute it later.
    #
    # We prepend per-subclass (via an +inherited+ hook plus a sweep of
    # already-defined subclasses) because a subclass's own #execute would
    # shadow a module prepended to RubyLLM::Tool itself.
    #
    # Mark a tool as having side effects by defining +dagcache_effectful?+
    # on the class:
    #
    #   class Refund < RubyLLM::Tool
    #     def self.dagcache_effectful? = true
    #     def execute(order_id:) = Payment.refund(order_id)
    #   end
    module ToolPatch
      def execute(**args)
        recorder = DagCache.recorder
        return super if recorder.nil?

        name = DagCache.tool_name_for(self)
        DagCache.register_tool_instance(name, self)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = super
        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        recorder.add_node(
          kind: "tool", name: name, purity: DagCache.purity_for(self),
          args_live: args, result_live: result, duration_ms: duration_ms
        )
        result
      end

      # Intercepts subclasses defined after dagcache is loaded.
      module InheritedHook
        def inherited(subclass)
          super
          ToolPatch.apply(subclass)
        end
      end

      def self.apply(tool_class)
        tool_class.prepend(self) unless tool_class.ancestors.include?(self)
      end

      def self.install!
        RubyLLM::Tool.singleton_class.prepend(InheritedHook)
        RubyLLM::Tool.subclasses.each { |subclass| apply(subclass) }
      end
    end
  end
end

RubyLLM::DagCache::ToolPatch.install! if defined?(RubyLLM::Tool)
