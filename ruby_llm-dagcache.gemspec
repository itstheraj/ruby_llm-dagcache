# frozen_string_literal: true

require_relative "lib/ruby_llm/dagcache/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-dagcache"
  spec.version = RubyLLM::DagCache::VERSION
  spec.authors = ["dagcache contributors"]
  spec.summary = "VCR cassettes for RubyLLM agent trajectories"
  spec.description = "Record RubyLLM agent runs as DAGs of tool/LLM calls, replay the canonical " \
                     "path on repeat tasks, and only call the LLM for net-new paths. " \
                     "Same mental model as the Python dagcache library."
  spec.homepage = "https://example.invalid/dagcache"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir.glob("lib/**/*.rb") + %w[README.md]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
end
