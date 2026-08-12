# frozen_string_literal: true

module RubyLLM
  module DagCache
    # Watch any object responding to +#ask+ (a RubyLLM::Agent, a Chat, or
    # your own wrapper). Returns a delegating wrapper; everything else
    # passes through to the underlying agent.
    #
    #   agent = RubyLLM::DagCache.watch(SupportAgent.new, key: ->(msg) { classify(msg) })
    #   agent.ask("refund my order O-123")
    #
    # +key:+ classifies messages into task kinds -- its return *value* is
    # mixed into the fingerprint, keeping "refund" and "weather" requests
    # (same shape!) in separate path caches.
    module Agent
      def self.watch(agent, kind: nil, key: nil)
        Wrapper.new(agent, kind || agent.class.name, key)
      end

      # Delegating wrapper around an agent.
      class Wrapper
        def initialize(agent, kind, key_fn)
          @agent = agent
          @kind = kind
          @key_fn = key_fn
        end

        def ask(message, **kwargs, &block)
          extra = @key_fn&.call(message)
          DagCache.run_cached(task_kind: @kind, inputs: { "message" => message }, key: extra) do
            @agent.ask(message, **kwargs, &block)
          end
        end

        def method_missing(name, ...)
          @agent.send(name, ...)
        end

        def respond_to_missing?(name, include_private = false)
          @agent.respond_to?(name, include_private) || super
        end
      end
    end
  end
end
