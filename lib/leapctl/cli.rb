# frozen_string_literal: true

module Leapctl
  # leapctl <command> [args...] [--name=value ...] [--yes]
  # Positional args fill the command's arguments in order; --name=value sets one by name.
  # Connection flags: --host= --cert= --key= --backup-dir= --snapshot= (or LEAP_* variables, or the config file).
  module CLI
    CONFIG_FLAGS = %w[host cert key backup-dir snapshot].freeze

    module_function

    def run(argv, out: $stdout)
      flags = {}
      positional = []
      argv.each do |a|
        if a =~ /\A--([a-z][a-z0-9-]*)(?:=(.*))?\z/m then flags[$1] = $2.nil? ? true : $2
        else positional << a
        end
      end
      name = positional.shift || 'help'
      config_opts = CONFIG_FLAGS.to_h { |f| [f.tr('-', '_'), flags.delete(f)] }.reject { |_, v| v.nil? || v == true }

      case name
      when 'help', '--help' then return help(positional.first, out)
      when 'version' then return out.puts("leapctl #{VERSION}")
      when 'setup' then return setup(flags, config_opts, out)
      when 'mcp' then return MCP.new(Config.load(config_opts)).run
      end

      cmd = Commands[name]
      args = {}
      # positional values fill the non-boolean arguments in order; booleans are flags only
      cmd.args.reject { |a| a.type == :boolean }.each_with_index { |a, i| args[a.name] = positional[i] if positional[i] }
      flags.each { |k, v| args[k.tr('-', '_')] = v unless %w[yes auto-program no-auto-program].include?(k) }
      args['auto_program'] = true if flags['auto-program']
      args['auto_program'] = false if flags['no-auto-program']
      if cmd.kind == :change && !flags['yes']
        raise Error, "#{name} changes the Lutron system (a backup is taken first). Add --yes to run it."
      end

      Client.open(Config.load(config_opts)) do |client|
        lines = Commands.call(client, name, args) { |msg| out.puts(msg); out.flush }
        out.puts(lines)
      end
    rescue Error, ArgumentError => e
      warn "leapctl: #{e.message}"
      exit 1
    end

    def setup(flags, config_opts, out)
      found = if flags['from-home-assistant']
                CertFinder.home_assistant(flags['from-home-assistant'] == true ? '/config' : flags['from-home-assistant'])
              elsif flags['from-pylutron']
                CertFinder.pylutron(flags['from-pylutron'] == true ? nil : flags['from-pylutron'])
              else
                []
              end
      raise Error, 'no certificates found there' if (flags['from-home-assistant'] || flags['from-pylutron']) && found.empty?
      raise Error, "several bridges found (#{found.map { |f| f['host'] }.join(', ')}): add --host=" if found.size > 1 && !config_opts['host']
      values = (found.find { |f| f['host'] == config_opts['host'] } || found.first || {}).merge(config_opts)
      raise Error, 'setup needs --host, --cert and --key (or --from-home-assistant=DIR / --from-pylutron)' unless %w[host cert key].all? { |k| values[k] }
      path = Config.save(values)
      out.puts "saved #{path}"
      Client.open(Config.load) { |c| out.puts(Commands.call(c, 'doctor', {})) }
    end

    def help(command, out)
      if command
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
        c.args.each { |a| out.puts "  #{a.type == :boolean ? "--#{a.name.tr('_', '-')}" : a.name}: #{a.desc}" }
        return
      end
      out.puts <<~TXT
        leapctl #{VERSION}: manage a Lutron Caséta / RA2 Select system over LEAP

        Setup:  leapctl setup --host=<bridge-ip> --cert=<file> --key=<file>
                leapctl setup --from-home-assistant=<HA config dir> | --from-pylutron[=<host>]
      TXT
      { read: 'Read', control: 'Control', change: 'Change (--yes; a backup is taken first)' }.each do |kind, title|
        out.puts "\n#{title}:"
        Commands::REGISTRY.values.select { |c| c.kind == kind }.each do |c|
          out.puts "  #{c.name.ljust(16)} #{c.desc}"
        end
      end
      out.puts "\nOther:  help <command> | mcp (MCP server on stdio, for Claude) | version"
    end
  end
end
