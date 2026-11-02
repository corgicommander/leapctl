# frozen_string_literal: true

module Leapctl
  # leapctl <command> [args...] [--name=value ...] [--yes]
  # Positional args fill the command's arguments in order; --name=value sets one by name.
  # Connection flags: --host= --cert= --key= --ca= --backup-dir= --snapshot= (or LEAP_* variables, or the config file).
  module CLI
    CONFIG_FLAGS = %w[host cert key ca backup-dir snapshot].freeze
    SWITCHES = %w[yes auto-program no-auto-program].freeze
    OTHER_HELP = {
      'setup' => ['leapctl setup --from-home-assistant=<HA config folder> [--host=<bridge IP>]',
                  '       leapctl setup --host=<bridge IP> --cert=<file> --key=<file> [--ca=<file>]   (or --from-pylutron[=<host>])',
                  '  Finds the client certificate (Home Assistant: the Lutron Caséta integration\'s files and the bridge',
                  '  address it saved), checks it, connects once, and only then saves the settings (paths only).'],
      'mcp' => ['leapctl mcp', '  Runs the MCP server on stdin/stdout, for Claude (the Claude Code plugin starts it).'],
      'version' => ['leapctl version', '  Prints the version.']
    }.freeze

    module_function

    def run(argv, out: $stdout)
      # names with accents, even when no language is set (LANG)
      Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8
      flags = {}
      positional = []
      argv.each do |a|
        a = a.dup.force_encoding(Encoding::UTF_8)
        if a == '-h' then flags['help'] = true
        elsif a =~ /\A--([a-z][a-z0-9-]*)(?:=(.*))?\z/m then flags[$1] = $2.nil? ? true : $2
        elsif a.start_with?('-') && a.size > 1 then raise Error, unknown_word(a)
        else positional << a
        end
      end
      name = positional.shift
      return out.puts("leapctl #{VERSION}") if name == 'version' || (name.nil? && flags['version'])
      return help(name == 'help' ? positional.first : name, out) if name.nil? || name == 'help' || flags['help']
      CONFIG_FLAGS.each { |f| raise Error, "--#{f} needs a value (--#{f}=...)" if flags[f] == true || flags[f].to_s.strip.empty? && flags.key?(f) }
      SWITCHES.each { |f| raise Error, "--#{f} takes no value#{f.end_with?('auto-program') ? ': use --auto-program or --no-auto-program' : ''}" if flags[f].is_a?(String) }
      config_opts = CONFIG_FLAGS.to_h { |f| [f.tr('-', '_'), flags.delete(f)] }.reject { |_, v| v.nil? }

      case name
      when 'setup' then return setup(flags, config_opts, positional, out)
      when 'mcp' then return MCP.new(config_opts).run
      end

      cmd = Commands[name]
      check_usage(cmd, flags, positional)
      args = {}
      # positional values fill the non-boolean arguments in order; booleans are flags only
      cmd.args.reject { |a| a.type == :boolean }.each_with_index { |a, i| args[a.name] = positional[i] if positional[i] }
      flags.each { |k, v| args[k.tr('-', '_')] = v unless SWITCHES.include?(k) }
      args['auto_program'] = true if flags['auto-program']
      args['auto_program'] = false if flags['no-auto-program']
      if cmd.kind == :change && !flags['yes']
        raise Error, "#{name} changes the Lutron system (a backup is taken first). Add --yes to run it."
      end

      Client.open(Config.load(config_opts)) do |client|
        lines = Commands.call(client, name, args) { |msg| out.puts(msg); out.flush }
        out.puts(lines.empty? ? '(none)' : lines)
      end
    rescue Error, ArgumentError => e
      warn "leapctl: #{e.message}"
      exit 1
    rescue Interrupt
      warn 'leapctl: stopped'
      exit 130
    rescue StandardError => e
      raise if Config.env('LEAPCTL_DEBUG')
      warn "leapctl: unexpected #{e.class}: #{e.message} (set LEAPCTL_DEBUG=1 to see where; please report it)"
      exit 1
    end

    # A word that looks like an option but isn't one leapctl reads; values never start with "-".
    def unknown_word(word)
      return 'unknown option -y (did you mean --yes?)' if word == '-y'
      name = word.sub(/\A-+/, '').split('=', 2).first.to_s
      "unknown option #{word.split('=', 2).first} (options look like --#{name.downcase.tr('_', '-')}=...; see `leapctl help`)"
    end

    # Refuses options the command doesn't have and extra words, so a typo never runs a different change.
    def check_usage(cmd, flags, positional)
      known = cmd.args.map { |a| a.name.tr('_', '-') } + ['yes']
      known += %w[auto-program no-auto-program] if cmd.args.any? { |a| a.name == 'auto_program' }
      unknown = flags.keys - known
      raise Error, "#{cmd.name}: unknown option #{unknown.map { |f| "--#{f}" }.join(', ')} (see `leapctl help #{cmd.name}`)" unless unknown.empty?
      bare = cmd.args.find { |a| a.type != :boolean && flags[a.name.tr('_', '-')] == true }
      raise Error, "#{cmd.name}: --#{bare.name.tr('_', '-')} needs a value (--#{bare.name.tr('_', '-')}=...)" if bare
      if cmd.args.any? { |a| a.name == 'auto_program' } && !flags['auto-program'] && !flags['no-auto-program']
        raise Error, "#{cmd.name}: add --no-auto-program (undo what Lutron's AutoProgrammer assigns) or --auto-program (keep it)"
      end
      slots = cmd.args.count { |a| a.type != :boolean }
      return if positional.size <= slots
      raise Error, "#{cmd.name}: too many arguments (#{positional.size} for #{slots}); put names with spaces in quotes"
    end

    def setup(flags, config_opts, positional, out)
      unknown = flags.keys - %w[from-home-assistant from-pylutron yes]
      raise Error, "setup: unknown option #{unknown.map { |f| "--#{f}" }.join(', ')} (see `leapctl help setup`)" unless unknown.empty?
      unless positional.empty?
        raise Error, "setup: unexpected #{positional.first.inspect}; did you mean --from-home-assistant=#{positional.first}?"
      end
      if flags['from-home-assistant'] == true && !File.directory?('/config')
        raise Error, '--from-home-assistant needs the folder: --from-home-assistant=<HA config folder>'
      end
      opts = config_opts.merge('from_home_assistant' => flags['from-home-assistant'], 'from_pylutron' => flags['from-pylutron'])
      out.puts(Setup.run(opts.reject { |_, v| v.nil? }))
    end

    def help(command, out)
      if command
        return out.puts(OTHER_HELP[command]) if OTHER_HELP[command]
        c = Commands[command]
        usage = c.args.map do |a|
          flag = a.name.tr('_', '-')
          if a.type == :boolean then "--#{flag}|--no-#{flag}"
          elsif a.required then "<#{a.name}>"
          else "[--#{flag}=...]"
          end
        end
        out.puts "leapctl #{c.name} #{usage.join(' ')}#{c.kind == :change ? ' --yes' : ''}"
        out.puts "  #{c.desc}"
        c.args.each do |a|
          if a.name == 'auto_program'
            out.puts '  --auto-program keeps what the AutoProgrammer assigns; --no-auto-program clears it and restores everything else'
          else
            out.puts "  #{a.name}: #{a.desc}"
          end
        end
        return
      end
      out.puts <<~TXT
        leapctl #{VERSION}: change what your Lutron Caséta / RA2 Select system does, over LEAP

        Setup:  leapctl setup --from-home-assistant=<HA config folder>
                leapctl setup --host=<bridge IP> --cert=<file> --key=<file>   (see `leapctl help setup`)
      TXT
      { read: 'Read', control: 'Control', change: 'Change (--yes; a backup is taken first)' }.each do |kind, title|
        out.puts "\n#{title}:"
        Commands::REGISTRY.values.select { |c| c.kind == kind }.each do |c|
          out.puts "  #{c.name.ljust(16)} #{c.desc}"
        end
      end
      out.puts "\nOther:  help <command> | <command> --help | mcp (MCP server on stdio, for Claude) | version"
    end
  end
end
