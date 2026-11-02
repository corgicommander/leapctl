# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'json'

module Leapctl
  # One TLS connection to the bridge (port 8081). LEAP messages are JSON lines terminated by CRLF;
  # responses are matched to requests by ClientTag, because the bridge also sends unsolicited events.
  class TlsTransport
    PORT = 8081
    TIMEOUT = 30
    CONNECT_TIMEOUT = 10 # for the TCP connection, and again for the TLS handshake

    def initialize(host, cert, key, ca: nil, port: PORT, connect_timeout: CONNECT_TIMEOUT)
      ctx = self.class.context(cert, key, ca)
      tcp = Socket.tcp(host, port, connect_timeout: connect_timeout)
      @ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      @ssl.sync_close = true
      handshake(connect_timeout)
      @tag = 0
      @buffer = String.new # bytes; each complete line is read as UTF-8
    rescue SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
      tcp&.close rescue nil
      raise Error, "can't connect to the bridge at #{host}:#{port}: #{e.message}#{self.class.hint(e, ca)}"
    end

    # Something that accepts on port 8081 but never answers TLS mustn't hang leapctl (or the MCP server).
    def handshake(seconds)
      deadline = Time.now + seconds
      begin
        @ssl.connect_nonblock
      rescue IO::WaitReadable
        raise Errno::ETIMEDOUT, 'no TLS answer' unless IO.select([@ssl.to_io], nil, nil, [deadline - Time.now, 0].max)
        retry
      rescue IO::WaitWritable
        raise Errno::ETIMEDOUT, 'no TLS answer' unless IO.select(nil, [@ssl.to_io], nil, [deadline - Time.now, 0].max)
        retry
      end
    end

    # TLS settings with the client certificate, and a check of the bridge's certificate when its CA
    # is known (pairing saves it; Home Assistant keeps it as lutron_caseta-…-ca.pem). Only the chain is
    # checked: the bridge's certificate names the bridge, not its address. Bad files fail here, before
    # connecting, with a one-line message.
    def self.context(cert, key, ca = nil)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = read_pem(cert, 'certificate') { |pem| OpenSSL::X509::Certificate.new(pem) }
      ctx.key = read_pem(key, 'private key') do |pem|
        raise Error, "#{key} is protected by a passphrase; leapctl needs the unencrypted key (the kind Home Assistant and lap-pair make)" if pem.include?('ENCRYPTED')
        OpenSSL::PKey.read(pem, '') # with a password given, OpenSSL never asks for one on the terminal or stdin
      end
      unless ctx.cert.check_private_key(ctx.key)
        raise Error, "the key #{key} doesn't belong to the certificate #{cert}#{cert.end_with?('-ca.pem') ? ' (use the -cert.pem file, not -ca.pem)' : ''}"
      end
      if ca
        store = OpenSSL::X509::Store.new # from the parsed file, so PEM and DER both work
        read_pem(ca, 'CA certificate', '') do |data|
          blocks = data.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m)
          (blocks.empty? ? [data] : blocks).each { |c| store.add_cert(OpenSSL::X509::Certificate.new(c)) }
        end
        ctx.cert_store = store
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
      else
        ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      ctx
    end

    # Reads the file as bytes (a CA file may be DER) and parses it in the block.
    def self.read_pem(path, what, format = 'PEM ')
      yield File.binread(path)
    rescue SystemCallError => e
      raise Error, "can't read the #{what} file: #{e.message}"
    rescue OpenSSL::X509::CertificateError, OpenSSL::X509::StoreError, OpenSSL::PKey::PKeyError, ArgumentError
      raise Error, "#{path} isn't a #{format}#{what}#{File.zero?(path) ? ' (the file is empty)' : ''}"
    end

    MOVED = '; if the bridge\'s address changed, run `leapctl setup --from-home-assistant=<HA config folder>` again (in Claude: lutron_setup)'

    # What a connection error most likely means.
    def self.hint(err, ca = nil)
      case err
      when Errno::ECONNREFUSED then " (is this the bridge's address? LEAP uses port #{PORT}#{MOVED})"
      when Errno::EHOSTUNREACH, Errno::ENETUNREACH
        mac = RUBY_PLATFORM.include?('darwin') ? '; on macOS this can also mean the app running leapctl lacks Local Network access: System Settings > Privacy & Security > Local Network' : ''
        " (no route to the bridge#{mac}#{MOVED})"
      when Errno::ETIMEDOUT, IOError then " (no answer: wrong address, or a firewall between this computer and the bridge#{MOVED})"
      when SocketError then ' (unknown host name; use the bridge\'s IP address)'
      when OpenSSL::SSL::SSLError
        if ca && err.message.include?('certificate verify failed')
          " (this isn't the bridge #{File.basename(ca)} belongs to: a wrong address, or a replaced bridge?)"
        else
          ' (the bridge refused the certificate: was it made for this bridge?)'
        end
      else ''
      end
    end

    def request(type, url, body = nil)
      tag = "c#{@tag += 1}"
      send_message(type, url, body, tag)
      deadline = Time.now + TIMEOUT
      loop do
        msg = next_message(deadline - Time.now) or raise Error, "no answer from the bridge for #{type} #{url}"
        return msg if msg.dig('Header', 'ClientTag') == tag
      end
    end

    def send_message(type, url, body = nil, tag = nil)
      msg = { CommuniqueType: type, Header: { Url: url } }
      msg[:Header][:ClientTag] = tag if tag
      msg[:Body] = body if body
      @ssl.write(msg.to_json + "\r\n")
    rescue SystemCallError, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "lost the connection to the bridge: #{e.message}"
    end

    # Next message from the bridge, or nil after timeout seconds.
    def next_message(timeout)
      loop do
        if (i = @buffer.index("\r\n"))
          line = @buffer.slice!(0, i + 2).strip.force_encoding(Encoding::UTF_8)
          next if line.empty?
          return Leapctl.scrub(JSON.parse(line)) rescue next
        end
        return nil if timeout <= 0
        ready = @ssl.pending.positive? || IO.select([@ssl.to_io], nil, nil, [timeout, 1].min)
        timeout -= 1 unless ready
        next unless ready
        begin
          @buffer << @ssl.read_nonblock(65_536)
        rescue IO::WaitReadable
          next
        rescue EOFError
          raise Error, 'the bridge closed the connection'
        rescue SystemCallError, IOError, OpenSSL::SSL::SSLError => e
          raise Error, "lost the connection to the bridge: #{e.message}"
        end
      end
    end

    def close
      @ssl.close
    rescue StandardError
      nil
    end
  end
end
