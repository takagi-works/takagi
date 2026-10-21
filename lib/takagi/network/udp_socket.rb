# frozen_string_literal: true

require 'socket'

module Takagi
  module Network
    # A UDP socket whose address family matches the address it will bind or talk to.
    #
    # `UDPSocket.new` opens an AF_INET socket, which cannot represent an IPv6 address: binding one
    # raises `SocketError`, and sending to one dies inside the resolver with
    # `getaddrinfo: No address associated with hostname`. Every UDP socket in the library goes
    # through here so that rule lives in exactly one place instead of five.
    module UdpSocket
      module_function

      def for(address)
        UDPSocket.new(family_for(address))
      end

      def family_for(address)
        Addrinfo.ip(unbracketed(address)).afamily
      rescue SocketError, ArgumentError
        Socket::AF_INET
      end

      # `URI#host` keeps an IPv6 literal's brackets (`"[::1]"`) while `URI#hostname` strips them,
      # and a bracketed literal is not resolvable - it would land in the rescue above and silently
      # produce an AF_INET socket, which is the exact failure this module exists to prevent.
      def unbracketed(address)
        address.to_s.delete_prefix('[').delete_suffix(']')
      end
    end
  end
end
