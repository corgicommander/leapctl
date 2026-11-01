# frozen_string_literal: true

require 'json'

module Leapctl
  # Minimal MCP server (JSON-RPC 2.0, one message per line on stdin/stdout) exposing every command as a
  # tool named lutron_<command>. Changes need confirm: true, and their descriptions tell the model to ask
  # the user first. Logs go to stderr; stdout carries only protocol messages.
  class MCP
    PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
    INSTRUCTIONS = <<~TXT
      Tools for a Lutron Caséta / RA2 Select system. Read freely. Before any tool that changes the system,
      say what it will do and get the user's OK, then call it with confirm: true (a backup is taken
      automatically; lutron_diff and lutron_restore can undo). Before lutron_pair or lutron_move_device,
      ask whether Lutron's AutoProgrammer should assign functions (auto_program true) or not (false).
      On engraved Picos (Kitchen, Bedside, ...) edits also go to the room's template, or the
      AutoProgrammer undoes them later; 3-button raise/lower Picos share one set of lights for all buttons.
    TXT

    # client: optional factory (tests pass one that builds a Client on a fake transport)
    def initialize(config, input: $stdin, output: $stdout, client: nil)
      @config = config
      @client = client || -> { Client.new(config) }
      @in = input
      @out = output
    end

    def run
      @out.sync = true
      @in.each_line do |line|
        msg = JSON.parse(line) rescue next
        handle(msg)
      end
    end

    def tools
      Commands::REGISTRY.values.map do |c|
        props = c.args.to_h do |a|
          [a.name, { type: { number: 'number', boolean: 'boolean' }.fetch(a.type, 'string'), description: a.desc }]
        end
        required = c.args.select(&:required).map(&:name)
        desc = c.desc.dup
        if c.kind == :change
          props['confirm'] = { type: 'boolean', description: 'true only after the user agreed to this change' }
          required << 'confirm'
          desc << '. Changes the Lutron system: ask the user first, then call with confirm: true. A backup is taken automatically.'
        end
        desc << ' Ask the user first whether the AutoProgrammer should assign functions.' if c.args.any? { |a| a.name == 'auto_program' }
        { name: "lutron_#{c.name.tr('-', '_')}", description: desc, inputSchema: { type: 'object', properties: props, required: required } }
      end
    end

    private

    def handle(msg)
      id = msg['id']
      case msg['method']
      when 'initialize'
        asked = msg.dig('params', 'protocolVersion')
        reply(id, protocolVersion: PROTOCOL_VERSIONS.include?(asked) ? asked : PROTOCOL_VERSIONS.first,
                  capabilities: { tools: {} }, serverInfo: { name: 'leapctl', version: VERSION }, instructions: INSTRUCTIONS)
      when 'tools/list' then reply(id, tools: tools)
      when 'tools/call' then reply(id, call_tool(msg['params'] || {}))
      when 'ping' then reply(id, {})
      else
        error(id, -32_601, "method not found: #{msg['method']}") if id
      end
    rescue StandardError => e
      error(id, -32_603, e.message) if id
    end

    def call_tool(params)
      name = params['name'].to_s.sub(/\Alutron_/, '').tr('_', '-')
      args = params['arguments'] || {}
      cmd = Commands[name]
      if cmd.kind == :change && args['confirm'] != true
        return text("Not done: #{cmd.name} changes the Lutron system. Describe the change to the user, and call again with confirm: true once they agree.", error: true)
      end
      token = params.dig('_meta', 'progressToken')
      step = 0
      client = @client.call
      lines = begin
        Commands.call(client, name, args) do |m|
          notify('notifications/progress', progressToken: token, progress: step += 1, message: m) if token
          warn(m)
        end
      ensure
        client.close
      end
      text(lines.join("\n"))
    rescue Error, ArgumentError => e
      text(e.message, error: true)
    end

    def text(body, error: false)
      { content: [{ type: 'text', text: body }], isError: error }
    end

    def reply(id, result)
      @out.puts({ jsonrpc: '2.0', id: id, result: result }.to_json)
    end

    def error(id, code, message)
      @out.puts({ jsonrpc: '2.0', id: id, error: { code: code, message: message } }.to_json)
    end

    def notify(method, params)
      @out.puts({ jsonrpc: '2.0', method: method, params: params }.to_json)
    end
  end
end
