# frozen_string_literal: true

# leapctl: manage a Lutron Caséta / RA2 Select system over LEAP, the bridge's local TLS protocol.
# Unofficial; not affiliated with Lutron Electronics. See README.md.
module Leapctl
  VERSION = '0.1.0'

  class Error < StandardError; end
end

require_relative 'leapctl/config'
require_relative 'leapctl/transport'
require_relative 'leapctl/client'
require_relative 'leapctl/commands'
require_relative 'leapctl/cli'
require_relative 'leapctl/mcp'
