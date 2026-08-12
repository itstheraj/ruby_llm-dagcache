# frozen_string_literal: true

require_relative "dagcache/version"
require_relative "dagcache/configuration"
require_relative "dagcache/keys"
require_relative "dagcache/graph"
require_relative "dagcache/bindings"
require_relative "dagcache/recorder"
require_relative "dagcache/store"
require_relative "dagcache/replay"
require_relative "dagcache/agent"

module RubyLLM
  # DagCache: VCR cassettes for agent trajectories.
  #
  # Record agent runs as DAGs of tool/LLM calls, replay the canonical path
  # on repeat tasks, and only pay for the LLM when the world diverges.
  #
  #   search = RubyLLM::DagCache.tool("search_kb", pure: true) { |query:| KB.search(query) }
  #   draft  = RubyLLM::DagCache.llm("draft") { |prompt| RubyLLM.chat.ask(prompt).content }
  #   agent  = RubyLLM::DagCache.watch(MyAgent.new, key: ->(msg) { classify(msg) })
  #   agent.ask("where is my order O-123")   # 1st: live + record; 2nd: replay
  module DagCache
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def reset_configuration!
        @configuration = nil
      end

      # -- registries ------------------------------------------------------

      def tools
        @tools ||= {}
      end

      def llms
        @llms ||= {}
      end

      def register_tool_instance(name, instance)
        tools[name] = { callable: ->(**a) { instance.execute(**a) }, style: :kwargs }
      end

      def tool_name_for(tool_instance)
        klass = tool_instance.class
        return klass.dagcache_name if klass.respond_to?(:dagcache_name)

        klass.name
      end

      def purity_for(tool_instance)
        klass = tool_instance.class
        klass.respond_to?(:dagcache_effectful?) && klass.dagcache_effectful? ? "effectful" : "pure"
      end

      # -- DSL -------------------------------------------------------------

      # Define a cacheable tool (keyword arguments, RubyLLM-style):
      #   search = DagCache.tool("search_kb", pure: true) { |query:| ... }
      #   search.call(query: "refunds")
      def tool(name, pure: true, &block)
        tools[name] = { callable: block, style: :kwargs }
        purity = pure ? "pure" : "effectful"
        lambda do |**args|
          recorder = Recorder.current
          return block.call(**args) if recorder.nil?

          result = block.call(**args)
          recorder.add_node(kind: "tool", name: name, purity: purity, args_live: args, result_live: result)
          result
        end
      end

      # Define an LLM call (positional arguments):
      #   draft = DagCache.llm("draft") { |prompt| ... }
      #   draft.call("write a reply about ...")
      # planning: true => decision call, never re-executed at replay.
      def llm(name, planning: false, &block)
        llms[name] = { callable: block, style: :positional }
        kind = planning ? "llm_plan" : "llm_output"
        lambda do |*args|
          recorder = Recorder.current
          return block.call(*args) if recorder.nil?

          args_live = args.each_with_index.to_h { |v, i| ["arg#{i}", v] }
          result = block.call(*args)
          recorder.add_node(kind: kind, name: name, purity: "llm", args_live: args_live, result_live: result)
          result
        end
      end

      # -- engine ----------------------------------------------------------

      def recorder
        Recorder.current
      end

      # Wrap any object responding to #ask (RubyLLM::Agent, Chat, or your
      # own class) so calls are recorded/replayed. See DagCache::Agent.
      def watch(agent, kind: nil, key: nil)
        Agent.watch(agent, kind: kind, key: key)
      end

      # The @agent equivalent: lookup -> replay -> (divergence? fall back)
      # -> run live while recording -> store candidate path.
      def run_cached(task_kind:, inputs:, key: nil)
        return yield unless configuration.enabled

        fingerprint = Keys.fingerprint(inputs, extra: key)
        store = Store.new(configuration.store_path)

        unless configuration.force_record
          dag = store.lookup(task_kind, fingerprint, auto_replay: configuration.auto_replay)
          if dag
            begin
              result = Replay::Executor.new(configuration.replay_mode).run(dag, inputs)
            rescue Replay::Divergence
              store.record_fallback(dag.id, demote_threshold: configuration.fallback_demote_threshold)
            else
              store.record_hit(dag.id)
              return result
            end
          end
        end

        recorder = Recorder.new(task_kind: task_kind, fingerprint: fingerprint, inputs: inputs)
        result = recorder.record { yield }
        store.save_dag(recorder.finalize, ttl_seconds: configuration.default_ttl_seconds) unless recorder.nodes.empty?
        result
      end
    end
  end
end

require_relative "dagcache/tool_patch"
