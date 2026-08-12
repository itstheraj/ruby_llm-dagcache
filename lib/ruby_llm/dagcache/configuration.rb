# frozen_string_literal: true

module RubyLLM
  module DagCache
    # Global configuration. Values mirror the Python library's policy.
    class Configuration
      attr_accessor :store_path, :enabled, :force_record, :replay_mode,
                    :auto_replay, :fallback_demote_threshold, :default_ttl_seconds

      def initialize
        @store_path = ENV.fetch("DAGCACHE_STORE", ".dagcache")
        @enabled = ENV["DAGCACHE_MODE"] != "off"
        @force_record = ENV["DAGCACHE_MODE"] == "record"
        @replay_mode = ENV.fetch("DAGCACHE_REPLAY", "verified").to_sym # :verified | :frozen
        @auto_replay = true # replay staging DAGs, not only approved ones
        @fallback_demote_threshold = 3
        @default_ttl_seconds = nil
      end

      def replay_mode=(value)
        value = value.to_sym
        raise ArgumentError, "replay_mode must be :verified or :frozen" unless %i[verified frozen].include?(value)

        @replay_mode = value
      end
    end
  end
end
