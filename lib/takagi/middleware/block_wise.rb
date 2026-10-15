# frozen_string_literal: true

require 'digest'
require_relative '../coap/block_wise'
require_relative '../hooks'
require_relative '../response_builder'

module Takagi
  module Middleware
    # State for the Block1 (request) direction of a block-wise transfer.
    #
    # Holds the in-flight assemblies of {BlockWise}, one per (token, path) pair, and
    # bounds them by the `block_wise` configuration: `max_assembled_bytes` caps one
    # body, `assembly_ttl` expires idle ones and `max_concurrent_assemblies` caps the
    # table by evicting the least recently used entry. Included into {BlockWise},
    # which owns the protocol replies.
    module BlockWiseAssembly
      # One in-flight Block1 assembly, keyed by token and request path.
      Assembly = Struct.new(:szx, :expected_num, :buffer, :updated_at, :path, :token, keyword_init: true)
      # The result of feeding one Block1 block into the assembly table.
      Outcome = Struct.new(:status, :payload, :reason, :events, keyword_init: true)

      private

      # Key an assembly by the token and path it belongs to. The middleware contract
      # exposes no peer address, so two peers sharing an empty token and path would
      # share a buffer; clients that transfer block-wise send a token (RFC 7959 §2.5).
      #
      # @param request [Takagi::Message::Inbound]
      # @return [Array(String, String)]
      def assembly_key(request)
        [request.token.to_s.b, request.uri.path.to_s]
      end

      # Assemble one block. Must be called with @mutex held.
      #
      # @param key [Array(String, String)]
      # @param request [Takagi::Message::Inbound]
      # @param option [Takagi::CoAP::BlockWise::OptionValue]
      # @param settings [Object]
      # @return [Outcome]
      def feed_block1(key, request, option, settings)
        events = purge_expired_assemblies(settings)
        entry = option.num.zero? ? start_assembly(key, request, option, settings, events) : @assemblies[key]
        return failed(request, :missing_start, events, option) if entry.nil?
        return failed(request, :out_of_order, events, option) if option.szx != entry.szx || option.num != entry.expected_num

        entry.buffer << request.payload.to_s.b
        entry.expected_num += 1
        entry.updated_at = @clock.call
        check_cap(key, request, option, entry, settings, events)
      end

      # Continue while more blocks are coming, complete on the last one, fail over the cap.
      #
      # @return [Outcome]
      def check_cap(key, request, option, entry, settings, events)
        limit = settings.max_assembled_bytes
        if limit && entry.buffer.bytesize > limit
          @assemblies.delete(key)
          return failed(request, :too_large, events, option)
        end

        return Outcome.new(status: :continue, payload: nil, events: events) if option.more?

        @assemblies.delete(key)
        events << [:block_transfer_completed, transfer_payload(request, :block1, option.num, option.szx, entry.buffer.bytesize)]
        Outcome.new(status: :complete, payload: entry.buffer.dup, events: events)
      end

      # Open a new assembly for a transfer starting at NUM 0, evicting the oldest if full.
      #
      # @return [Assembly]
      def start_assembly(key, request, option, settings, events)
        evict_oldest(settings, events)
        entry = Assembly.new(szx: option.szx, expected_num: 0, buffer: String.new(encoding: Encoding::BINARY),
                             updated_at: @clock.call, path: request.uri.path, token: request.token)
        @assemblies[key] = entry
        events << [:block_transfer_started, transfer_payload(request, :block1, 0, option.szx, 0)]
        entry
      end

      # @param settings [Object]
      # @param events [Array<Array(Symbol, Hash)>] hook events accumulated for this request
      def evict_oldest(settings, events)
        limit = settings.max_concurrent_assemblies
        return if limit.nil? || @assemblies.size < limit

        key, evicted = @assemblies.min_by { |_, entry| entry.updated_at }
        @assemblies.delete(key)
        events << [:block_transfer_failed, entry_payload(evicted, :evicted)]
      end

      # Drop assemblies older than `assembly_ttl`. Must be called with @mutex held.
      #
      # @param settings [Object]
      # @return [Array<Array(Symbol, Hash)>] failure events for the dropped assemblies
      def purge_expired_assemblies(settings)
        ttl = settings.assembly_ttl
        return [] if ttl.nil?

        now = @clock.call
        events = []
        @assemblies.select { |_, entry| now - entry.updated_at > ttl }.each do |key, entry|
          @assemblies.delete(key)
          events << [:block_transfer_failed, entry_payload(entry, :assembly_expired)]
        end
        events
      end

      # @param request [Takagi::Message::Inbound]
      # @param reason [Symbol] why the transfer failed
      # @param events [Array<Array(Symbol, Hash)>]
      # @param option [Takagi::CoAP::BlockWise::OptionValue]
      # @return [Outcome]
      def failed(request, reason, events, option)
        events << [:block_transfer_failed, transfer_payload(request, :block1, option.num, option.szx, nil).merge(reason: reason)]
        Outcome.new(status: :failed, payload: nil, reason: reason, events: events)
      end

      # @param request [Takagi::Message::Inbound]
      # @param direction [Symbol] :block1 or :block2
      # @param num [Integer]
      # @param szx [Integer]
      # @param size [Integer, nil] representation size in bytes
      # @return [Hash] the hook payload for one transfer step
      def transfer_payload(request, direction, num, szx, size)
        { direction: direction, num: num, szx: szx, size: size,
          path: request.uri.path, token: request.token }
      end

      # @param entry [Assembly]
      # @param reason [Symbol]
      # @return [Hash]
      def entry_payload(entry, reason)
        { direction: :block1, num: entry.expected_num - 1, szx: entry.szx, size: entry.buffer.bytesize,
          path: entry.path, token: entry.token, reason: reason }
      end
    end

    # RFC 7959 block-wise transfer for UDP servers, transparent to route handlers.
    #
    # On the way out a response whose serialized payload is larger than one block goes
    # out as the Block2 slice the client asked for (M, NUM, SZX, Size2 and an ETag);
    # on the way in a request that arrives as a Block1 sequence is buffered and the
    # handler receives the reassembled body as one payload. Messages that fit in a
    # single block, responses that are not 2.xx and TCP messages (RFC 8323 block-wise
    # is out of scope) pass through untouched.
    #
    # Disable the feature with `block_wise: { enabled: false }` in takagi.yml, and see
    # {BlockWiseAssembly} for the assembly limits.
    #
    # Every transfer emits `Takagi::Hooks` events: `:block_transfer_started`,
    # `:block_transfer_completed` and `:block_transfer_failed`.
    #
    # @see Takagi::CoAP::BlockWise the extraction-ready codec behind it
    class BlockWise
      include BlockWiseAssembly

      # Marker returned by {#decode_block_option} when an option value cannot be decoded.
      INVALID = :invalid

      # @param config [Object, nil] block_wise settings, defaults to `Takagi.config.block_wise`
      # @param clock [#call, nil] monotonic clock source, injectable for TTL tests
      def initialize(config: nil, clock: nil)
        @config = config
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @assemblies = {}
        @mutex = Mutex.new
        @logger = Takagi.logger
      end

      # Runs one request through block-wise handling.
      #
      # @param request [Takagi::Message::Inbound] inbound CoAP request
      # @param downstream [#call] the rest of the middleware chain, called as `downstream.call(request)`
      # @return [Takagi::Message::Outbound, Object] a block reply, or the handler's own result
      def call(request, &downstream)
        settings = block_wise_settings
        return downstream.call(request) unless settings&.enabled && !request.message_id.nil?

        block1 = decode_block_option(request, CoAP::Registries::Option::BLOCK1)
        block2 = decode_block_option(request, CoAP::Registries::Option::BLOCK2)
        return bad_option(request, 'malformed Block option') if [block1, block2].include?(INVALID)
        return assemble_block1(request, block1, block2, settings, &downstream) if block1 && !single_block?(block1)

        slice_response(request, downstream.call(request), block2, settings)
      end

      private

      # Block-wise settings, read per request so a late `load_file` is honoured.
      #
      # @return [Object, nil] the block_wise config, or nil when unavailable
      def block_wise_settings
        @config || (Takagi.config.block_wise if Takagi.config.respond_to?(:block_wise))
      end

      # A Block1 request whose only block is the last one already carries the whole body.
      #
      # @param option [Takagi::CoAP::BlockWise::OptionValue, nil]
      # @return [Boolean]
      def single_block?(option)
        !option.nil? && option.num.zero? && !option.more?
      end

      # Decode a Block1/Block2 option value. Only an absent option is nil: a zero-length
      # value is the valid NUM 0 / M 0 / SZX 0 block option (RFC 7252 §3.2).
      #
      # @param request [Takagi::Message::Inbound]
      # @param number [Integer] option number
      # @return [Takagi::CoAP::BlockWise::OptionValue, Symbol, nil] value, {INVALID}, or nil
      def decode_block_option(request, number)
        raw = Array(request.option(number)).first
        return nil if raw.nil?

        CoAP::BlockWise::OptionValue.decode(raw)
      rescue CoAP::BlockWise::DecodeError
        INVALID
      end

      # Send the requested Block2 slice of a response that exceeds one block.
      #
      # @param request [Takagi::Message::Inbound]
      # @param result [Object] whatever the rest of the chain returned
      # @param block2 [Takagi::CoAP::BlockWise::OptionValue, nil] requested block
      # @param settings [Object]
      # @return [Takagi::Message::Outbound, Object]
      def slice_response(request, result, block2, settings)
        outbound = coerce_outbound(request, result)
        return result unless outbound && CoAP::Registries::Response.success?(outbound.code)

        payload = outbound.payload.to_s.b
        szx = negotiated_szx(block2, settings)
        num = block2 ? block2.num : 0
        return outbound if fits_one_block?(payload, szx, num)

        blocks = CoAP::BlockWise.slice(payload, szx: szx)
        return bad_option(request, "Block2 NUM #{num} is past the end") if num >= blocks.size

        emit_block2_events(request, blocks[num], szx, payload.bytesize)
        block_response(request, outbound, blocks[num], payload.bytesize)
      end

      # A response this small is not a block transfer, and NUM 0 asks for the whole thing.
      #
      # @param payload [String]
      # @param szx [Integer]
      # @param num [Integer]
      # @return [Boolean]
      def fits_one_block?(payload, szx, num)
        num.zero? && payload.bytesize <= CoAP::BlockWise::OptionValue.size_for(szx)
      end

      # The server never offers a larger block than the client asked for.
      #
      # @param block2 [Takagi::CoAP::BlockWise::OptionValue, nil]
      # @param settings [Object]
      # @return [Integer] SZX to slice with
      def negotiated_szx(block2, settings)
        server_szx = (settings.szx || CoAP::BlockWise::OptionValue::MAX_SZX).to_i
        block2 ? [block2.szx, server_szx].min : server_szx
      end

      # Build the single-block response carrying an ETag (RFC 7959 §2.4) and Size2.
      #
      # @param request [Takagi::Message::Inbound]
      # @param outbound [Takagi::Message::Outbound] the full handler response being sliced
      # @param block [Takagi::CoAP::BlockWise::Block] slice to send
      # @param size [Integer] total representation size
      # @return [Takagi::Message::Outbound]
      def block_response(request, outbound, block, size)
        options = (outbound.options || {}).each_with_object({}) { |(number, value), acc| acc[number] = Array(value).dup }
        options[CoAP::Registries::Option::BLOCK2] = [block.option_value]
        options[CoAP::Registries::Option::ETAG] = [Digest::SHA256.digest(outbound.payload).byteslice(0, 8)]
        options[CoAP::Registries::Option::SIZE2] = [uint_bytes(size)] if block.num.zero?

        request.to_response(outbound.code, block.payload, options: options)
      end

      # Normalize a handler result into an Outbound so its payload size is known.
      #
      # @param request [Takagi::Message::Inbound]
      # @param result [Object]
      # @return [Takagi::Message::Outbound, nil] nil when the result is not a representation
      def coerce_outbound(request, result)
        return result if result.is_a?(Takagi::Message::Outbound)
        return nil unless result.is_a?(Hash) || result.is_a?(String)

        Takagi::ResponseBuilder.respond(request, result, logger: @logger)
      end

      # @param request [Takagi::Message::Inbound]
      # @param block [Takagi::CoAP::BlockWise::Block]
      # @param szx [Integer]
      # @param size [Integer]
      def emit_block2_events(request, block, szx, size)
        if block.num.zero? && block.more?
          Takagi::Hooks.emit(:block_transfer_started, transfer_payload(request, :block2, 0, szx, size))
        elsif !block.more?
          Takagi::Hooks.emit(:block_transfer_completed, transfer_payload(request, :block2, block.num, szx, size))
        end
      end

      # Feed one Block1 block into the assembly table and answer accordingly.
      #
      # @param request [Takagi::Message::Inbound]
      # @param option [Takagi::CoAP::BlockWise::OptionValue] the request's Block1 option
      # @param block2 [Takagi::CoAP::BlockWise::OptionValue, nil]
      # @param settings [Object]
      # @param downstream [#call] the rest of the chain, called with the assembled request
      # @return [Takagi::Message::Outbound, Object]
      def assemble_block1(request, option, block2, settings, &downstream)
        outcome = @mutex.synchronize { feed_block1(assembly_key(request), request, option, settings) }
        outcome.events.each { |event, payload| Takagi::Hooks.emit(event, payload) }
        case outcome.status
        when :continue then continue_response(request, option)
        when :complete then slice_response(request, downstream.call(reassembled_request(request, outcome.payload)), block2, settings)
        else failure_response(request, outcome, settings)
        end
      end

      # Graft the assembled body onto a private copy of the request, dropping the
      # Block1 option: the middleware contract only exposes parsed messages and the
      # original request must stay untouched for the server's duplicate cache.
      #
      # @param request [Takagi::Message::Inbound]
      # @param payload [String] assembled body
      # @return [Takagi::Message::Inbound]
      def reassembled_request(request, payload)
        copy = request.dup
        copy.instance_variable_set(:@payload, payload)
        copy.instance_variable_set(:@options, (request.options || {}).reject { |number, _| number == CoAP::Registries::Option::BLOCK1 })
        copy
      end

      # 2.31 Continue, echoing the Block1 option (RFC 7959 §2.5).
      #
      # @param request [Takagi::Message::Inbound]
      # @param option [Takagi::CoAP::BlockWise::OptionValue]
      # @return [Takagi::Message::Outbound]
      def continue_response(request, option)
        value = CoAP::BlockWise::OptionValue.encode(num: option.num, more: true, szx: option.szx)
        request.to_response(CoAP::Registries::Response::CONTINUE, ''.b,
                            options: { CoAP::Registries::Option::BLOCK1 => [value] })
      end

      # 4.13 when the body exceeds the cap, 4.08 for a gap, a restart or an eviction.
      #
      # @param request [Takagi::Message::Inbound]
      # @param outcome [Outcome]
      # @param settings [Object]
      # @return [Takagi::Message::Outbound]
      def failure_response(request, outcome, settings)
        @logger.debug "Block-wise request failed: #{outcome.reason}"
        return too_large_response(request, settings) if outcome.reason == :too_large

        request.to_response(CoAP::Registries::Response::REQUEST_ENTITY_INCOMPLETE, { error: 'Request entity incomplete' })
      end

      # 4.13 Request Entity Too Large, advertising the cap via Size1 (RFC 7959 §2.9.3).
      #
      # @param request [Takagi::Message::Inbound]
      # @param settings [Object]
      # @return [Takagi::Message::Outbound]
      def too_large_response(request, settings)
        limit = settings.max_assembled_bytes
        options = limit ? { CoAP::Registries::Option::SIZE1 => [uint_bytes(limit)] } : {}

        request.to_response(CoAP::Registries::Response::REQUEST_ENTITY_TOO_LARGE,
                            { error: 'Request entity too large' }, options: options)
      end

      # 4.02 Bad Option for a malformed Block1/Block2 value or an out-of-range NUM.
      #
      # @param request [Takagi::Message::Inbound]
      # @param message [String]
      # @return [Takagi::Message::Outbound]
      def bad_option(request, message)
        @logger.debug "Block-wise bad option: #{message}"
        request.to_response(CoAP::Registries::Response::BAD_OPTION, { error: message })
      end

      # Minimal big-endian encoding for a uint option value (Size1/Size2).
      #
      # @param value [Integer]
      # @return [String]
      def uint_bytes(value)
        bytes = [value.to_i].pack('N').bytes
        bytes.shift while bytes.length > 1 && bytes.first.zero?
        bytes.pack('C*')
      end
    end
  end
end
