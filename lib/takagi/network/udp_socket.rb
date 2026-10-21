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
    #
    # The family is taken from the LITERAL, never from a resolution: a colon appears in an IPv6
    # literal and in no reg-name or IPv4address, which is the same test `Forwarder#bracketed_host`
    # uses. Resolving instead would let `localhost` decide the family, and that choice is not stable
    # across hosts - where it prefers `::1` the socket becomes AF_INET6 and a datagram sent to an
    # IPv4-bound peer is accepted by `send` and then silently never arrives.
    module UdpSocket
      module_function

      def for(address)
        UDPSocket.new(family_for(address))
      end

      def family_for(address)
        unbracketed(address).include?(':') ? Socket::AF_INET6 : Socket::AF_INET
      end

      # `URI#host` keeps an IPv6 literal's brackets (`"[::1]"`) where `URI#hostname` strips them, so
      # both spellings are normalized onto one path here. The brackets carry a colon of their own,
      # so the test above would answer AF_INET6 either way; this is what keeps that from depending
      # on which of the two spellings a caller happened to pass.
      def unbracketed(address)
        address.to_s.delete_prefix('[').delete_suffix(']')
      end
    end
  end
end
