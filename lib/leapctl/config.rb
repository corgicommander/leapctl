# frozen_string_literal: true

require 'json'
require 'fileutils'

module Leapctl
  # Where the bridge is, which client certificate to use, and where backups go.
  #
  # Sources, highest priority first: explicit options (CLI flags), environment variables
  # (LEAP_HOST, LEAP_CERT, LEAP_KEY, LEAP_CA, LEAP_BACKUP_DIR, LEAP_SNAPSHOT), then the config file
  # (LEAPCTL_CONFIG, or ~/.config/leapctl/config.json). The config file only holds paths, never
  # the certificate or key themselves.
  class Config
    KEYS = %w[host cert key ca backup_dir snapshot].freeze
    PATHS = %w[cert key ca backup_dir snapshot].freeze
    NOT_SET_UP = 'leapctl isn\'t set up yet: run `leapctl setup --from-home-assistant=<HA config folder>` ' \
                 '(in Claude: the lutron_setup tool), or set LEAP_HOST, LEAP_CERT and LEAP_KEY'

    attr_reader :values

    # An environment variable, or nil when it is unset or blank. Read as UTF-8: without a language
    # setting (LANG), which is how Claude starts programs, Ruby would mark an accented path as binary.
    def self.env(name)
      v = ENV[name].to_s.dup.force_encoding(Encoding::UTF_8).scrub.strip
      v.empty? ? nil : v
    end

    def self.home
      Dir.home.dup.force_encoding(Encoding::UTF_8)
    end

    def self.path
      env('LEAPCTL_CONFIG') || File.join(env('XDG_CONFIG_HOME') || File.join(home, '.config'), 'leapctl', 'config.json')
    end

    # For paths on a Mac's network shares, such as Home Assistant's config folder over Samba: only when
    # the share itself isn't there.
    def self.share_hint(path)
      share = path.to_s[%r{\A/Volumes/[^/]+}]
      share && !File.directory?(share) ? " (#{share} isn't there: is that network share mounted?)" : ''
    end

    def self.read_file
      return {} unless File.exist?(path)
      file = JSON.parse(File.read(path, encoding: 'UTF-8'))
      file.is_a?(Hash) ? file : raise(JSON::ParserError)
    rescue JSON::ParserError
      raise Error, "can't read #{path}: it isn't a leapctl settings file (run setup again to replace it)"
    rescue SystemCallError => e
      raise Error, "can't read #{path}: #{e.message.sub(/ @ .*/, '').sub(/ - .*/, '')} (fix its permissions, or run setup again to replace it)"
    end

    def self.load(options = {})
      file = read_file
      new(KEYS.to_h do |k|
        # skip blanks, and placeholders a plugin host left unexpanded (e.g. "${user_config.host}")
        v = [options[k], options[k.to_sym], env("LEAP_#{k.upcase}"), file[k]].find { |x| !x.to_s.strip.empty? && !x.to_s.include?('${') }
        [k, v]
      end)
    end

    # Merges values into the config file (keeping its other settings; a nil value removes one) and
    # returns the file's path. File paths are saved absolute, so the settings work from any folder. A
    # file that can't be read is kept as config.json.bak and replaced. A symlinked file (dotfiles) is
    # written through the link.
    def self.save(values)
      existing = begin
        read_file
      rescue Error
        FileUtils.cp(path, "#{path}.bak") rescue nil
        {}
      end
      merged = existing.merge(values).reject { |_, v| v.nil? || v.to_s.strip.empty? }
      merged = merged.to_h { |k, v| [k, PATHS.include?(k) ? File.expand_path(v) : v] }
      target = File.symlink?(path) ? (File.realpath(path) rescue path) : path
      FileUtils.mkdir_p(File.dirname(target))
      File.write("#{target}.tmp", JSON.pretty_generate(merged) + "\n")
      File.rename("#{target}.tmp", target)
      path
    end

    def initialize(values)
      @values = values
    end

    def host
      @values['host'] or raise Error, NOT_SET_UP
    end

    def cert
      file('cert')
    end

    def key
      file('key')
    end

    # The bridge's CA certificate, if known: then leapctl checks that it talks to that bridge.
    def ca
      @values['ca'] && file('ca')
    end

    def backup_dir
      File.expand_path(@values['backup_dir'] ||
        File.join(Config.env('XDG_DATA_HOME') || File.join(Config.home, '.local', 'share'), 'leapctl', 'backups'))
    end

    # Optional: a fixed path that every backup also writes (handy to keep in git and diff).
    def snapshot
      @values['snapshot'] && File.expand_path(@values['snapshot'])
    end

    private

    def file(k)
      path = @values[k] or raise Error, NOT_SET_UP
      path = File.expand_path(path)
      return path if File.exist?(path)
      raise Error, "#{k} file not found: #{path}#{Config.share_hint(path)}"
    end
  end

  # Finds existing LEAP client certificates so users don't have to pair again. Each result is a hash
  # with 'cert' and 'key' paths, 'ca' when the bridge's CA file is there too, and 'host' or (when only
  # Lutron's ID for the bridge is known) 'lutron_id'.
  module CertFinder
    module_function

    # Home Assistant's Lutron Caséta integration keeps the bridge's certificate files in its config
    # folder, and the bridge's address in .storage/core.config_entries. Only the lutron_caseta entries
    # of that file are looked at (it also holds other integrations' settings), and only their address
    # and file names are kept.
    def home_assistant(config_dir)
      if config_dir.to_s =~ %r{\A\w+://}
        raise Error, "#{config_dir} is the share's network address: connect to it in Finder (Go > Connect to Server), " \
                     'then give the folder it appears as (usually /Volumes/config)'
      end
      dir = File.expand_path(config_dir)
      dir = File.dirname(dir) if File.basename(dir) == 'configuration.yaml' && File.file?(dir)
      raise Error, "no such folder: #{dir}#{Config.share_hint(dir)}" unless File.directory?(dir)
      found = ha_config_entries(dir)
      found.empty? ? ha_file_names(dir) : found
    end

    def ha_config_entries(dir)
      path = File.join(dir, '.storage', 'core.config_entries')
      return [] unless File.readable?(path)
      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      entries = data.is_a?(Hash) ? Array(data.dig('data', 'entries')) : []
      entries.select { |e| e.is_a?(Hash) && e['domain'] == 'lutron_caseta' && e['source'] != 'ignore' }.map do |e|
        d = e['data'].is_a?(Hash) ? e['data'] : {}
        with_ca({ 'host' => d['host'], 'cert' => ha_path(dir, d['certfile']), 'key' => ha_path(dir, d['keyfile']) },
                ha_path(dir, d['ca_certs']))
      end.select { |c| c['host'] && c['cert'] && c['key'] && File.exist?(c['cert']) && File.exist?(c['key']) }
    rescue JSON::ParserError, TypeError
      []
    end

    # HA stores these paths relative to its config folder (/config inside Home Assistant OS).
    def ha_path(dir, file)
      return nil unless file.is_a?(String) && !file.empty?
      return File.join(dir, file.sub(%r{\A/config/}, '')) if file.start_with?('/config/')
      file.start_with?('/') ? file : File.join(dir, file)
    end

    # The files alone: lutron_caseta-<host>-cert.pem, where <host> is the address you typed into
    # Home Assistant, or Lutron's ID for the bridge when Home Assistant found the bridge by itself.
    def ha_file_names(dir)
      Dir[File.join(dir, 'lutron_caseta-*-cert.pem')].map do |cert|
        name = File.basename(cert)[/\Alutron_caseta-(.+)-cert\.pem\z/, 1]
        found = with_ca({ 'cert' => cert, 'key' => cert.sub(/-cert\.pem\z/, '-key.pem') }, cert.sub(/-cert\.pem\z/, '-ca.pem'))
        found.merge(name =~ /[.:]/ ? { 'host' => name } : { 'lutron_id' => name })
      end.select { |c| File.exist?(c['key']) }
    end

    # pylutron-caseta's `lap-pair <host>` writes ~/.config/pylutron_caseta/<host>.crt, <host>.key and
    # <host>-bridge.crt (the bridge's CA).
    def pylutron(host = nil)
      dir = File.join(Config.env('XDG_CONFIG_HOME') || File.join(Config.home, '.config'), 'pylutron_caseta')
      Dir[File.join(dir, '*.key')].map do |key|
        h = File.basename(key, '.key')
        with_ca({ 'host' => h, 'cert' => File.join(dir, "#{h}.crt"), 'key' => key }, File.join(dir, "#{h}-bridge.crt"))
      end.select { |c| File.exist?(c['cert']) && (host.nil? || c['host'] == host) }
    end

    def with_ca(found, ca)
      ca && File.exist?(ca) ? found.merge('ca' => ca) : found
    end
  end
end
