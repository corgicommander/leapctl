# frozen_string_literal: true

require 'openssl'
require 'socket'

module Leapctl
  # `leapctl setup` and the lutron_setup tool: find or take a client certificate, check it, connect
  # once, and only then save the settings.
  module Setup
    module_function

    # opts (string keys): 'from_home_assistant' (a folder, or true for /config), 'from_pylutron' (a host,
    # or true), 'host', 'cert', 'key', 'ca'. Returns lines: where the settings went, then doctor's report.
    # connect: builds the client for the test connection (the tests pass one with a fake bridge).
    def run(opts, connect: ->(config) { Client.new(config) })
      values = settings(opts).merge(opts.select { |k, v| %w[backup_dir snapshot].include?(k) && v })
      check_files(values['cert'], values['key'])
      saved = begin
        Config.load.values
      rescue Error
        {} # an unreadable settings file gets replaced below
      end
      client = connect.call(Config.new(saved.merge(values)))
      report = begin
        Commands.call(client, 'doctor', {})
      ensure
        client.close
      end
      ["saved #{Config.save(values)}"] + overridden(values) + report
    end

    # Environment variables beat the settings file, so say when one will hide what was just saved.
    def overridden(values)
      %w[host cert key ca backup_dir snapshot].map do |k|
        v = Config.env("LEAP_#{k.upcase}")
        next if v.nil? || v.include?('${') || values[k].nil?
        next if (k == 'host' ? v == values[k] : File.expand_path(v) == File.expand_path(values[k]))
        "note: LEAP_#{k.upcase} is set in the environment and overrides the saved #{k.tr('_', ' ')}; unset it to use the saved one"
      end.compact
    end

    # The address, client files and CA are one set: a setup that brings no CA turns the check off
    # (ca nil), instead of keeping a CA that belongs to the previous bridge.
    # resolver: finds a bridge's address from Lutron's ID for it (the tests pass a stand-in).
    def settings(opts, resolver: method(:resolve))
      ha = opts['from_home_assistant']
      found = if ha then CertFinder.home_assistant(ha == true ? '/config' : ha)
              elsif opts['from_pylutron'] then CertFinder.pylutron(opts['from_pylutron'] == true ? nil : opts['from_pylutron'])
              else []
              end
      if ha && found.empty?
        raise Error, "no Lutron Caséta certificate in #{File.expand_path(ha == true ? '/config' : ha)}: point at the folder " \
                     "with Home Assistant's configuration.yaml, and check that the Lutron Caséta integration is set up there"
      end
      raise Error, 'no certificate from pylutron-caseta\'s lap-pair found in ~/.config/pylutron_caseta' if opts['from_pylutron'] && found.empty?
      pick = opts['cert'] && opts['key'] ? match(found, opts['cert'], opts['key']) : pick(found, opts['host'])
      values = %w[host cert key ca].to_h { |k| [k, opts[k] || pick[k]] }
      values['host'] ||= resolver.call(pick['lutron_id']) if pick['lutron_id']
      if values['host'].nil? && pick['lutron_id']
        raise Error, "Home Assistant found this bridge by itself, so its files are named after Lutron's ID for it " \
                     "(#{pick['lutron_id']}), not its address. Add --host=<bridge IP address>."
      end
      missing = %w[host cert key].reject { |k| values[k] }
      unless missing.empty?
        raise Error, "setup needs #{missing.map { |k| "--#{k}" }.join(', ')}#{found.empty? ? ', or --from-home-assistant=<HA config folder>' : ''}"
      end
      values.map { |k, v| [k, k == 'host' || v.nil? ? v : File.expand_path(v)] }.to_h
    end

    # With --cert and --key as well as a folder to search, take only what belongs to those files
    # (the address and CA saved with them).
    def match(found, cert, key)
      return {} if found.empty?
      found.find { |f| same_file?(f['cert'], cert) && same_file?(f['key'], key) } or
        raise Error, 'those certificate and key files aren\'t the ones found in that folder; leave out the folder to use them as they are'
    end

    def same_file?(a, b)
      File.expand_path(a) == File.expand_path(b) || (File.exist?(a) && File.exist?(b) && File.realpath(a) == File.realpath(b))
    end

    def pick(found, host)
      return found.first || {} if found.size <= 1
      names = found.map { |f| f['host'] || f['lutron_id'] }.join(', ')
      raise Error, "several bridges found (#{names}): add --host=<bridge IP>" unless host
      found.find { |f| f['host'] == host } or
        raise Error, "#{host} isn't one of the bridges found (#{names})" +
                     (found.any? { |f| f['lutron_id'] } ? '; for one known only by Lutron\'s ID, also give its --cert and --key files' : '')
    end

    # The bridge announces itself as lutron-<id>.local (mDNS); that only resolves on the bridge's own subnet.
    def resolve(lutron_id)
      Addrinfo.getaddrinfo("lutron-#{lutron_id}.local", nil, :INET, :STREAM).first&.ip_address
    rescue SocketError
      nil
    end

    # Catches the usual mistakes before anything is saved: empty or non-PEM files, swapped files, the
    # CA file given as the key, and a key that doesn't belong to the certificate.
    def check_files(cert_path, key_path)
      { 'cert' => cert_path, 'key' => key_path }.each do |what, path|
        raise Error, "#{what} file not found: #{path}#{Config.share_hint(path)}" unless File.file?(path)
      end
      key_is_cert = pem?(key_path) { |pem| OpenSSL::X509::Certificate.new(pem) }
      cert_is_key = pem?(cert_path) { |pem| OpenSSL::PKey.read(pem, '') }
      raise Error, 'the certificate and key are swapped: --cert takes the certificate, --key the private key' if key_is_cert && cert_is_key
      raise Error, "#{key_path} is a certificate, not a private key (Home Assistant's key file ends in -key.pem)" if key_is_cert
      raise Error, "#{cert_path} is a private key, not a certificate (Home Assistant's certificate ends in -cert.pem)" if cert_is_key
      TlsTransport.context(cert_path, key_path)
    end

    def pem?(path)
      yield File.read(path)
      true
    rescue StandardError
      false
    end
  end
end
