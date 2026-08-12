# ruby_llm-dagcache

**VCR cassettes for RubyLLM agent trajectories** — a RubyLLM plugin on the
same mental model as the companion Python **`dagcache`** library.

Watch an agent run, infer the DAG of tool/LLM calls it made, freeze the
canonical path, and replay it on repeat tasks. The LLM only fires for
genuinely new paths.

## Usage

```ruby
require "ruby_llm"          # the real gem
require "ruby_llm/dagcache"

RubyLLM::DagCache.configure do |c|
  c.store_path = ".dagcache"      # one YAML cassette per DAG
  c.replay_mode = :verified       # or :frozen (VCR mode, nothing executes)
end

class Weather < RubyLLM::Tool
  description "Get current weather"
  def execute(latitude:, longitude:) = WeatherAPI.current(latitude, longitude)
end

class Refund < RubyLLM::Tool
  def self.dagcache_effectful? = true   # side effects: re-run on replay, keep order
  def execute(order_id:) = Payment.refund(order_id)
end

agent = RubyLLM::DagCache.watch(MyAgent.new, key: ->(msg) { classify(msg) })
agent.ask("refund order O-123")   # 1st call: live + record
agent.ask("refund order O-456")   # 2nd call: replay, zero LLM planning
```

- `RubyLLM::Tool` subclasses are instrumented **automatically** (an
  `inherited` hook prepends the recorder into each tool class — subclass
  `execute` overrides would shadow a plain prepend on `RubyLLM::Tool`).
- `watch` wraps anything responding to `#ask` (an Agent, a Chat, your own
  class) and passes everything else through.
- `key:` classifies tasks — its return **value** is mixed into the
  fingerprint, keeping same-shaped tasks ("refund" vs "weather") in
  separate path caches. Without it, all string prompts share one shape.

For non-RubyLLM code, or finer control, use the DSL:

```ruby
search = RubyLLM::DagCache.tool("search_kb", pure: true) { |query:| KB.search(query) }
plan   = RubyLLM::DagCache.llm("planner", planning: true) { |prompt| chat.ask(prompt).content }
draft  = RubyLLM::DagCache.llm("draft") { |prompt| chat.ask(prompt).content }
```

## How it works (same as the Python side)

- **Cache key = the chain, not the args**: task kind + structural
  fingerprint of inputs. Values never participate in matching.
- **Args are re-bindable slots**: inferred as `input` (from the call
  arguments), `node` (from an upstream node's output), or `literal`
  (LLM-synthesized). At replay, bindings resolve against fresh data.
- **verified replay**: re-execute tools (real side effects, fresh data),
  skip planning LLM calls, re-run output LLM calls with prompts patched to
  fresh values. Any drift (shape change, unresolvable binding, tool error)
  falls back to the live agent automatically.
- **Cassettes are YAML files** in `.dagcache/`, one per DAG, meant to be
  reviewed in git. Statuses: `staging` → `approved` (canonical) → `dead`
  (too many fallbacks). Competing paths for the same task rank by
  hits + recordings; approved always wins.

## Configuration

| Setting | Default | Env |
|---|---|---|
| `store_path` | `.dagcache` | `DAGCACHE_STORE` |
| `replay_mode` | `:verified` | `DAGCACHE_REPLAY` |
| `enabled` / `force_record` | on | `DAGCACHE_MODE=off\|record` |
| `auto_replay` | `true` (staging replays too) | — |
| `fallback_demote_threshold` | `3` | — |
| `default_ttl_seconds` | `nil` | — |

## Limitations

Same honest list as the Python library: exact matching only (fuzzy is a
footgun with effectful tools), verified replay re-runs side effects,
synthesized literals can go stale, prompt patching is a heuristic, and the
watched `ask`'s return value should be its final LLM/tool call's result.

## Tests

```
ruby -Ilib -Itest test/test_end_to_end.rb   # or: rake test
```

The suite uses a fake `RubyLLM::Tool` — no API keys required.
