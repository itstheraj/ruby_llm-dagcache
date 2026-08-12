# frozen_string_literal: true

require "fileutils"
require "time"
require "yaml"

module RubyLLM
  module DagCache
    # Persistence: one YAML cassette per DAG in the store directory --
    # VCR-gem style, diffable in code review. Rows are keyed by
    # (task_kind, fingerprint, path_key): recording the same chain for the
    # same task shape again just bumps +recordings+ -- repetition is how a
    # path earns "canonical". Competing paths coexist and rank by stats.
    class Store
      def initialize(dir)
        @dir = dir
        FileUtils.mkdir_p(dir)
      end

      def save_dag(dag, ttl_seconds: nil)
        existing = load_all.find do |d|
          d.task_kind == dag.task_kind && d.fingerprint == dag.fingerprint && d.path_key == dag.path_key
        end
        if existing
          existing.recordings += 1
          existing.nodes = dag.nodes
          persist(existing)
          existing.id
        else
          dag.id = next_id
          dag.status = "staging"
          dag.created_at = Time.now.utc.iso8601
          dag.ttl_seconds = ttl_seconds
          persist(dag)
          dag.id
        end
      end

      def lookup(task_kind, fingerprint, auto_replay: true)
        candidates = load_all.select do |d|
          d.task_kind == task_kind && d.fingerprint == fingerprint &&
            (d.status == "approved" || (auto_replay && d.status == "staging")) &&
            !expired?(d)
        end
        candidates.min_by { |d| [d.status == "approved" ? 0 : 1, -(d.hits + d.recordings), d.id] }
      end

      def get(id)
        load_all.find { |d| d.id == id }
      end

      def record_hit(id)
        update(id) { |d| d.hits += 1 }
      end

      def record_fallback(id, demote_threshold: 3)
        update(id) do |d|
          d.fallbacks += 1
          d.status = "dead" if d.status == "staging" && demote_threshold.positive? && d.fallbacks >= demote_threshold
        end
      end

      def approve(id) = update(id) { |d| d.status = "approved" }
      def demote(id) = update(id) { |d| d.status = "staging" }

      def prune(status: nil)
        dropped = load_all.select { |d| status.nil? || d.status == status }
        dropped.each { |d| FileUtils.rm_f(file_for(d.id)) }
        dropped.size
      end

      def load_all
        Dir.glob(File.join(@dir, "*.yml")).sort.map do |file|
          from_storage(YAML.safe_load_file(file))
        end
      end

      private

      def update(id)
        dag = get(id)
        return false unless dag

        yield dag
        persist(dag)
        true
      end

      def persist(dag)
        File.write(file_for(dag.id), YAML.dump(to_storage(dag)))
      end

      def file_for(id)
        File.join(@dir, format("%<id>04d.yml", id: id))
      end

      def next_id
        (load_all.map(&:id).max || 0) + 1
      end

      def expired?(dag)
        return false if dag.ttl_seconds.nil? || dag.created_at.nil?

        Time.now.utc > Time.iso8601(dag.created_at) + dag.ttl_seconds
      end

      def to_storage(dag)
        {
          "id" => dag.id, "task_kind" => dag.task_kind, "fingerprint" => dag.fingerprint,
          "status" => dag.status, "recordings" => dag.recordings, "hits" => dag.hits,
          "fallbacks" => dag.fallbacks, "created_at" => dag.created_at,
          "ttl_seconds" => dag.ttl_seconds, "dag" => dag.to_h
        }
      end

      def from_storage(hash)
        dag = DAG.from_h(hash["dag"])
        dag.id = hash["id"]
        dag.status = hash["status"]
        dag.recordings = hash["recordings"]
        dag.hits = hash["hits"]
        dag.fallbacks = hash["fallbacks"]
        dag.created_at = hash["created_at"]
        dag.ttl_seconds = hash["ttl_seconds"]
        dag
      end
    end
  end
end
