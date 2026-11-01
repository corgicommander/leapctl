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

    def initialize(host, cert, key, port: PORT)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(cert))
      ctx.key = OpenSSL::PKey.read(File.read(key))
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE # the bridge's certificate is self-signed
      @ssl = OpenSSL::SSL::SSLSocket.new(Socket.tcp(host, port, connect_timeout: 10), ctx)
      @ssl.sync_close = true
      @ssl.connect
      @tag = 0
      @buffer = +''
    rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      raise Error, "can't connect to the bridge at #{host}:#{port}: #{e.message}"
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
    end

    # Next message from the bridge, or nil after timeout seconds.
    def next_message(timeout)
      loop do
        if (i = @buffer.index("\r\n"))
          line = @buffer.slice!(0, i + 2).strip
          next if line.empty?
          return JSON.parse(line) rescue next
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
