# frozen_string_literal: true

module Takagi
  module Message
    # Implements CoAP retransmission logic as per RFC 7252 Section 4.2
    #
    # For CON (Confirmable) messages, the client MUST retransmit the message
    # until it receives an ACK, RST, or the transmission times out.
    #
    # RFC 7252 §4.2: Retransmission uses exponential back-off with random factor
    # RFC 7252 §4.8: Default transmission parameters
    class RetransmissionManager
      # RFC 7252 §4.8: Transmission parameters
      ACK_TIMEOUT = 2.0          # Initial timeout in seconds
      ACK_RANDOM_FACTOR = 1.5    # Random factor for timeout calculation
      MAX_RETRANSMIT = 4         # Maximum number of retransmissions

      # Pending transmission tracking
      PendingTransmission = Struct.new(
        :message_id,
        :message_data,
        :socket,
        :host,
        :port,
        :attempt,
        :next_timeout,
        :timeout_at,
        :callback
      ) do
        def timed_out?(current_time)
          current_time >= timeout_at
        end
      end

      def initialize(logger: nil)
        @pending = {}
        @mutex = Mutex.new
        @logger = logger || Takagi.logger
        @running = false
        @thread = nil
      end

      # Start the retransmission manager background thread
      def start
        return if @running

        @running = true
        @thread = Thread.new { run_retransmission_loop }
        @logger.debug 'Retransmission manager started'
      end

      # Stop the retransmission manager
      def stop
        @running = false
        @thread&.join
        @logger.debug 'Retransmission manager stopped'
      end

      # Send a CON message with automatic retransmission
      # @param message_id [Integer] CoAP Message ID
      # @param message_data [String] Serialized message bytes
      # @param socket [UDPSocket] Socket to send on
      # @param host [String] Destination host
      # @param port [Integer] Destination port
      # @param callback [Proc] Called with response or timeout error
      def send_confirmable(message_id, message_data, socket, host, port, &callback)
        initial_timeout = calculate_timeout(0)

        transmission = PendingTransmission.new(
          message_id,
          message_data,
          socket,
          host,
          port,
          0, # attempt
          initial_timeout,
          Time.now.to_f + initial_timeout,
          callback
        )

        @mutex.synchronize do
          @pending[message_id] = transmission
        end

        # Send initial transmission
        transmit(transmission)

        @logger.debug "Scheduled CON message (MID: #{message_id}) with timeout #{initial_timeout}s"
      end

      # Handle incoming ACK or RST to cancel retransmission
      # @param message_id [Integer] CoAP Message ID
      # @param response_data [String] Response message data
      def handle_response(message_id, response_data = nil)
        type = message_type(response_data)
        return unless CoAP::Registries::MessageType.acknowledgement?(type) || CoAP::Registries::MessageType.reset?(type)

        transmission = @mutex.synchronize { @pending.delete(message_id) }

        return unless transmission

        @logger.debug "Received response for MID: #{message_id}, canceling retransmission"
        return if type == CoAP::Registries::MessageType::ACK && response_data.getbyte(1).zero?

        transmission.callback&.call(response_data, nil)
      end

      # Get statistics about pending transmissions
      def stats
        @mutex.synchronize do
          {
            pending_count: @pending.size,
            message_ids: @pending.keys
          }
        end
      end

      private

      def message_type(response_data)
        return nil unless response_data.is_a?(String) && response_data.bytesize >= 4

        (response_data.getbyte(0) >> 4) & 0b11
      end

      # Main retransmission loop
      def run_retransmission_loop
        while @running
          sleep 0.1 # Check every 100ms

          process_timeouts
        end
      rescue StandardError => e
        @logger.error "Retransmission loop error: #{e.message}"
        @logger.error e.backtrace.join("\n")
      end

      # Process timed out transmissions
      def process_timeouts
        current_time = Time.now.to_f
        timed_out = []

        @mutex.synchronize do
          @pending.each_value do |transmission|
            timed_out << transmission if transmission.timed_out?(current_time)
          end
        end

        timed_out.each do |transmission|
          handle_timeout(transmission)
        end
      end

      # Handle a transmission timeout
      def handle_timeout(transmission)
        if transmission.attempt >= MAX_RETRANSMIT
          # Max retries exceeded
          @mutex.synchronize do
            @pending.delete(transmission.message_id)
          end

          @logger.warn "Message #{transmission.message_id} failed after #{MAX_RETRANSMIT} retransmissions"
          transmission.callback&.call(nil, 'Timeout: Max retransmissions exceeded')
        else
          # Retransmit with exponential backoff
          transmission.attempt += 1
          transmission.next_timeout = calculate_timeout(transmission.attempt)
          transmission.timeout_at = Time.now.to_f + transmission.next_timeout

          transmit(transmission)

          @logger.debug "Retransmitting MID: #{transmission.message_id} " \
                        "(attempt #{transmission.attempt}/#{MAX_RETRANSMIT}, " \
                        "next timeout: #{transmission.next_timeout}s)"
        end
      end

      # Transmit a message
      def transmit(transmission)
        transmission.socket.send(
          transmission.message_data,
          0,
          transmission.host,
          transmission.port
        )
      rescue StandardError => e
        @logger.error "Transmission failed for MID #{transmission.message_id}: #{e.message}"
      end

      # Calculate timeout with exponential backoff and random factor
      # RFC 7252 §4.2: timeout = ACK_TIMEOUT * (2 ** attempt) * random_factor
      # where random_factor is between 1.0 and ACK_RANDOM_FACTOR
      def calculate_timeout(attempt)
        base_timeout = ACK_TIMEOUT * (2**attempt)
        random_factor = 1.0 + (rand * (ACK_RANDOM_FACTOR - 1.0))
        base_timeout * random_factor
      end
    end
  end
end
