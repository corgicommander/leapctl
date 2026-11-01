# frozen_string_literal: true

require 'json'
require 'fileutils'

module Leapctl
  # Where the bridge is, which client certificate to use, and where backups go.
  #
  # Sources, highest priority first: explicit options (CLI flags), environment variables
  # (LEAP_HOST, LEAP_CERT, LEAP_KEY, LEAP_BACKUP_DIR, LEAP_SNAPSHOT), then the config file
  # (LEAPCTL_CONFIG, or ~/.config/leapctl/config.json). The config file only holds paths, never
  # the certificate or key themselves.
  class Config
    KEYS = %w[host cert key backup_dir snapshot].freeze

    attr_reader :values

    def self.path
      ENV['LEAPCTL_CONFIG'] || File.join(ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config'), 'leapctl', 'config.json')
    end

    def self.load(options = {})
      file = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      new(KEYS.to_h do |k|
        # skip blanks, and placeholders a plugin host left unexpanded (e.g. "${user_config.host}")
        v = [options[k], options[k.to_sym], ENV["LEAP_#{k.upcase}"], file[k]].find { |x| !x.to_s.strip.empty? && !x.to_s.include?('${') }
        [k, v]
      end)
    end

    def self.save(values)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(values.reject { |_, v| v.to_s.empty? }) + "\n")
      path
    end

    def initialize(values)
      @values = values
    end

    def host
      @values['host'] or raise Error, 'no bridge address: run `leapctl setup` or set LEAP_HOST'
    end

    def cert
      file('cert')
    end

    def key
      file('key')
    end

    def backup_dir
      @values['backup_dir'] ||
        File.join(ENV['XDG_DATA_HOME'] || File.join(Dir.home, '.local', 'share'), 'leapctl', 'backups')
    end

    # Optional: a fixed path that every backup also writes (handy to keep in git and diff).
    def snapshot
      @values['snapshot']
    end

    private

    def file(k)
      path = @values[k] or raise Error, "no client #{k}: run `leapctl setup` or set LEAP_#{k.upcase}"
      path = File.expand_path(path)
      raise Error, "#{k} file not found: #{path}" unless File.exist?(path)
      path
    end
  end

  # Finds existing LEAP client certificates so users don't have to pair again.
  module CertFinder
    module_function

    # Home Assistant's Lutron Caséta integration keeps lutron_caseta-<host>-{cert,key}.pem in its config dir.
    def home_assistant(config_dir)
      Dir[File.join(File.expand_path(config_dir), 'lutron_caseta-*-cert.pem')].map do |cert|
        host = File.basename(cert)[/\Alutron_caseta-(.+)-cert\.pem\z/, 1]
        { 'host' => host, 'cert' => cert, 'key' => cert.sub(/-cert\.pem\z/, '-key.pem') }
      end.select { |c| File.exist?(c['key']) }
    end

    # pylutron-caseta's `lap-pair <host>` writes ~/.config/pylutron_caseta/<host>.crt and <host>.key.
    def pylutron(host = nil)
      dir = File.join(ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config'), 'pylutron_caseta')
      Dir[File.join(dir, '*.key')].map do |key|
        h = File.basename(key, '.key')
        { 'host' => h, 'cert' => File.join(dir, "#{h}.crt"), 'key' => key }
      end.select { |c| File.exist?(c['cert']) && (host.nil? || c['host'] == host) }
    end
  end
end
