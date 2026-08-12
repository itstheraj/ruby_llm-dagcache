#!/usr/bin/env ruby
# frozen_string_literal: true

# A narrated, API-key-free demo: record one agent run, replay the next.
# Run with:  ruby examples/demo.rb

require_relative "../lib/ruby_llm/dagcache"
require "tmpdir"
require "yaml"

DC = RubyLLM::DagCache

BOLD  = "\e[1m"
DIM   = "\e[2m"
GREEN = "\e[32m"
CYAN  = "\e[36m"
PINK  = "\e[35m"
GRAY  = "\e[90m"
RESET = "\e[0m"

def section(title)
  puts
  puts "#{BOLD}#{CYAN}== #{title} #{RESET}"
  sleep 0.6
end

# --- a fake world: no API keys, just latency ---------------------------------

$world = { status: "shipped" }
$spend = Hash.new(0.0)

def llm_call(label, prompt)
  latency = 0.9
  $spend[:llm] += latency
  puts "  #{PINK}◆ LLM #{label}#{RESET} #{GRAY}(#{latency}s, $$$)#{RESET} #{DIM}#{prompt[0, 52]}#{RESET}"
  sleep latency
  "[#{label}: #{prompt}]"
end

STORE = Dir.mktmpdir("dagcache-demo")
DC.configure { |c| c.store_path = STORE; c.replay_mode = :verified }

search = DC.tool("search_kb", pure: true) do |query:|
  puts "  #{GREEN}🔧 tool search_kb#{RESET}   #{DIM}query=#{query[0, 40]}#{RESET}"
  "kb-article about #{query}"
end
fetch = DC.tool("fetch_order", pure: true) do |order_id:|
  puts "  #{GREEN}🔧 tool fetch_order#{RESET}  #{DIM}order_id=#{order_id} (live status: #{$world[:status]})#{RESET}"
  { "order_id" => order_id, "status" => $world[:status] }
end
send_reply = DC.tool("send_reply", pure: false) do |ticket_id:, body:|
  puts "  #{GREEN}🔧 tool send_reply#{RESET}   #{DIM}ticket=#{ticket_id} — side effect executed!#{RESET}"
  "sent:#{ticket_id} (#{body[0, 32]}…)"
end
plan  = DC.llm("planner", planning: true) { |prompt| llm_call("planning", prompt); "search -> fetch -> send -> draft" }
draft = DC.llm("drafter") { |prompt| llm_call("drafting", prompt); "reply: #{prompt}" }

agent = Object.new
agent.define_singleton_method(:ask) do |ticket|
  plan.call("handle #{ticket['title']}")
  article = search.call(query: ticket["title"])
  order = fetch.call(order_id: ticket["order_id"])
  send_reply.call(ticket_id: ticket["id"], body: "see #{article}")
  draft.call("article=#{article}; status=#{order['status']}")
end

agent = DC.watch(agent, kind: "support_ticket")

puts "#{BOLD}ruby_llm-dagcache demo#{RESET} — VCR cassettes for agent trajectories"
sleep 1.0

section "Run 1 · ticket T-100 · LIVE (nothing cached yet)"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = agent.ask({ "id" => "T-100", "title" => "where is my order", "order_id" => "O-100" })
puts "  #{GRAY}=> #{result[0, 64]}#{RESET}"
puts "  #{BOLD}#{format('%.1f', Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)}s#{RESET} · trajectory recorded to cassette"
sleep 1.2

section "The world moves on: order O-200 is now 'delivered'"
$world[:status] = "delivered"
sleep 0.8

section "Run 2 · ticket T-200 · REPLAY (same task shape, fresh data)"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = agent.ask({ "id" => "T-200", "title" => "package never arrived", "order_id" => "O-200" })
puts "  #{GRAY}=> #{result[0, 64]}#{RESET}"
puts "  #{BOLD}#{format('%.1f', Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)}s#{RESET} · planning LLM skipped, fresh values ✅"
sleep 1.4

section "The cassette (one YAML per DAG, review in git)"
file = Dir[File.join(STORE, "*.yml")].first
yaml = YAML.load_file(file)
names = yaml["dag"]["nodes"].map { |n| n["name"] }
puts "  #{GRAY}#{File.basename(file)} · status: #{yaml['status']} · hits: #{yaml['hits']}#{RESET}"
puts "  #{GRAY}nodes: #{names.join(' → ')}#{RESET}"
sleep 1.6

puts
puts "#{BOLD}Same chain, new values → replay. New chain → LLM fires.#{RESET}"
sleep 1.5
