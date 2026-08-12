# 📼 ruby_llm-dagcache

> **VCR cassettes for [RubyLLM](https://github.com/crmne/ruby_llm) agents** —
> record what an agent did once, replay it the next time the same kind of
> task comes in. The LLM only runs when something genuinely new happens.

[![Ruby >= 3.1](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Built for RubyLLM](https://img.shields.io/badge/built%20for-RubyLLM-7048e8)](https://github.com/crmne/ruby_llm)
[![Python sibling: dagcache](https://img.shields.io/badge/python%20sibling-dagcache-3776AB?logo=python&logoColor=white)](https://github.com/itstheraj/dag_cache)

Same idea as the Python library
**[`dagcache`](https://github.com/itstheraj/dag_cache)**, and the same
record-and-replay philosophy as [VCR](https://github.com/vcr/vcr) — but for
agent runs instead of HTTP calls.

## 🎬 Demo

![Terminal demo: record one run, replay the next with zero LLM planning](docs/demo.gif)

Run it yourself — no API keys needed:

```sh
ruby examples/demo.rb
```

## 🚀 Usage

```ruby
require "ruby_llm"          # the real gem
require "ruby_llm/dagcache"

RubyLLM::DagCache.configure do |c|
  c.store_path = ".dagcache"      # one YAML cassette per run
  c.replay_mode = :verified       # or :frozen (VCR mode, nothing executes)
end

class Weather < RubyLLM::Tool
  description "Get current weather"
  def execute(latitude:, longitude:) = WeatherAPI.current(latitude, longitude)
end

class Refund < RubyLLM::Tool
  def self.dagcache_effectful? = true   # has side effects: re-run on replay, keep order
  def execute(order_id:) = Payment.refund(order_id)
end

agent = RubyLLM::DagCache.watch(MyAgent.new, key: ->(msg) { classify(msg) })
agent.ask("refund order O-123")   # 1st call: live + record
agent.ask("refund order O-456")   # 2nd call: replay, no LLM planning
```

**Good to know:**

- 🔧 `RubyLLM::Tool` subclasses are picked up **automatically**. An
  `inherited` hook adds the recorder to each tool class (a plain prepend on
  `RubyLLM::Tool` wouldn't work — subclass `execute` methods would shadow it).
- 👀 `watch` wraps anything with an `#ask` method (an Agent, a Chat, your own
  class). Everything else passes through untouched.
- 🗝️ `key:` tells runs apart — its return value goes into the cache key, so
  "refund" tasks and "weather" tasks get separate caches. Without it, all
  string prompts share one cache.

Not using RubyLLM, or want more control? Use the DSL:

```ruby
search = RubyLLM::DagCache.tool("search_kb", pure: true) { |query:| KB.search(query) }
plan   = RubyLLM::DagCache.llm("planner", planning: true) { |prompt| chat.ask(prompt).content }
draft  = RubyLLM::DagCache.llm("draft") { |prompt| chat.ask(prompt).content }
```

## 🧠 How it works

Same design as [the Python side](https://github.com/itstheraj/dag_cache):

- **The cache key is the chain of calls, not the arguments.** Two runs match
  when they make the same calls in the same shape — the actual values don't
  matter.
- **Arguments are slots that get re-filled at replay.** Each one is either an
  `input` (from the request), a `node` output (from an earlier call), or a
  `literal` (written by the LLM).
- **Replay is verified, not blind.** Tools run again for real (fresh data,
  real side effects), planning LLM calls are skipped, and output LLM calls
  re-run with prompts updated to the fresh values. If anything doesn't line
  up — shape changed, a value can't be resolved, a tool fails — the live
  agent takes over automatically.
- **Cassettes are plain YAML** in `.dagcache/`, one per run, meant to be
  reviewed in git. They move `staging` → `approved` (the canonical path) →
  `dead` (failed too often). If several paths fit one task, the one with the
  most hits and recordings wins; an approved path always wins.

## ⚙️ Configuration

| Setting | Default | Env |
|---|---|---|
| `store_path` | `.dagcache` | `DAGCACHE_STORE` |
| `replay_mode` | `:verified` | `DAGCACHE_REPLAY` |
| `enabled` / `force_record` | on | `DAGCACHE_MODE=off\|record` |
| `auto_replay` | `true` (staging replays too) | — |
| `fallback_demote_threshold` | `3` | — |
| `default_ttl_seconds` | `nil` | — |

## ⚠️ Limitations

Same honest list as [the Python library](https://github.com/itstheraj/dag_cache):
matching is exact (fuzzy matching is dangerous with side-effecting tools),
replay re-runs side effects, LLM-written literals can go stale, prompt
patching is a heuristic, and the watched `ask` should return the result of
its final LLM/tool call.

## 🧪 Tests

```sh
ruby -Ilib -Itest test/test_end_to_end.rb   # or: rake test
```

The suite uses a fake `RubyLLM::Tool` — no API keys required.

## 🔗 Related projects

- [**dagcache**](https://github.com/itstheraj/dag_cache) — the Python original; same idea, same cassettes.
- [**RubyLLM**](https://github.com/crmne/ruby_llm) — the Ruby LLM library this gem plugs into.
- [**VCR**](https://github.com/vcr/vcr) — the record-and-replay HTTP library that inspired this.

## 📄 License

[MIT](LICENSE)
