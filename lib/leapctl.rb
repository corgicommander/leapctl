# frozen_string_literal: true

# leapctl: manage a Lutron Caséta / RA2 Select system over LEAP, the bridge's local TLS protocol.
# Unofficial; not affiliated with Lutron Electronics. See README.md.
module Leapctl
  VERSION = '0.1.1'

  class Error < StandardError; end

  # Parsed JSON with every string made valid UTF-8: JSON allows escapes (a lone \udfff) that decode to
  # invalid UTF-8, which would break the output later.
  def self.scrub(value)
    case value
    when String then value.valid_encoding? ? value : value.scrub
    when Array then value.map { |v| scrub(v) }
    when Hash then value.to_h { |k, v| [scrub(k), scrub(v)] }
    else value
    end
  end
end

require_relative 'leapctl/config'
require_relative 'leapctl/transport'
require_relative 'leapctl/client'
require_relative 'leapctl/commands'
require_relative 'leapctl/setup'
require_relative 'leapctl/cli'
require_relative 'leapctl/mcp'
