# frozen_string_literal: true

require 'rspec'
require_relative '../../lib/takagi/message/retransmission_manager'

RSpec.describe Takagi::Message::RetransmissionManager do
  let(:manager) { described_class.new }
  let(:socket) { instance_double(UDPSocket) }
  let(:message_id) { 12_345 }
  let(:message_data) { "\x40\x01\x30\x39test".b }
  let(:host) { 'localhost' }
  let(:port) { 5683 }

  before do
    allow(socket).to receive(:send)
  end

  after do
    manager.stop if manager.instance_variable_get(:@running)
  end

  def datagram(type:, code:, message_id: 12_345, token: ''.b)
    type_bits = { con: 0, non: 1, ack: 2, rst: 3 }.fetch(type)
    [(0x40 | (type_bits << 4) | token.bytesize), code, message_id].pack('CCn') + token
  end

  describe '#initialize' do
    it 'initializes with empty pending transmissions' do
      expect(manager.stats[:pending_count]).to eq(0)
    end

    it 'is not running by default' do
      expect(manager.instance_variable_get(:@running)).to be false
    end
  end

  describe '#start and #stop' do
    it 'starts the retransmission manager' do
      manager.start
      expect(manager.instance_variable_get(:@running)).to be true
      expect(manager.instance_variable_get(:@thread)).to be_a(Thread)
    end

    it 'stops the retransmission manager' do
      manager.start
      manager.stop
      expect(manager.instance_variable_get(:@running)).to be false
    end

    it 'does not start multiple times' do
      manager.start
      thread1 = manager.instance_variable_get(:@thread)
      manager.start
      thread2 = manager.instance_variable_get(:@thread)
      expect(thread1).to eq(thread2)
    end
  end

  describe '#send_confirmable' do
    before { manager.start }

    it 'sends initial transmission immediately' do
      expect(socket).to receive(:send).with(message_data, 0, host, port)

      manager.send_confirmable(message_id, message_data, socket, host, port)
    end

    it 'adds transmission to pending list' do
      manager.send_confirmable(message_id, message_data, socket, host, port)
      stats = manager.stats

      expect(stats[:pending_count]).to eq(1)
      expect(stats[:message_ids]).to include(message_id)
    end

    it 'calls callback on successful response' do
      callback_called = false
      response_data = 'response'

      manager.send_confirmable(message_id, message_data, socket, host, port) do |resp, err|
        callback_called = true
        expect(resp).to eq(response_data)
        expect(err).to be_nil
      end

      manager.handle_response(message_id, response_data)
      expect(callback_called).to be true
    end
  end

  describe '#handle_response' do
    before { manager.start }

    it 'removes transmission from pending list' do
      manager.send_confirmable(message_id, message_data, socket, host, port)
      expect(manager.stats[:pending_count]).to eq(1)

      manager.handle_response(message_id, 'response')
      expect(manager.stats[:pending_count]).to eq(0)
    end

    it 'does nothing if message_id not found' do
      expect { manager.handle_response(99_999, 'response') }.not_to raise_error
    end

    it 'cancels the transmission on an Acknowledgement of the request' do
      manager.send_confirmable(message_id, message_data, socket, host, port)

      manager.handle_response(message_id, datagram(type: :ack, code: 0x45))

      expect(manager.stats[:pending_count]).to eq(0)
    end

    it 'cancels the transmission on a Reset of the request and hands it back' do
      answer = nil
      manager.send_confirmable(message_id, message_data, socket, host, port) { |resp, _err| answer = resp }
      reset = datagram(type: :rst, code: 0x00)

      manager.handle_response(message_id, reset)

      expect(manager.stats[:pending_count]).to eq(0)
      expect(answer).to eq(reset)
    end

    it 'cancels the transmission on an Empty Acknowledgement without handing it back' do
      answer = nil
      manager.send_confirmable(message_id, message_data, socket, host, port) { |resp, _err| answer = resp }

      manager.handle_response(message_id, datagram(type: :ack, code: 0x00))

      expect(manager.stats[:pending_count]).to eq(0)
      expect(answer).to be_nil
    end

    it 'keeps the transmission pending for a datagram that is neither an Acknowledgement nor a Reset' do
      manager.send_confirmable(message_id, message_data, socket, host, port)

      manager.handle_response(message_id, datagram(type: :non, code: 0x45))

      expect(manager.stats[:pending_count]).to eq(1)
    end
  end

  describe 'RFC 7252 §4.2 retransmission behavior' do
    before { manager.start }

    it 'uses exponential backoff for timeouts' do
      timeouts = (0..4).map do |attempt|
        manager.send(:calculate_timeout, attempt)
      end

      # Each timeout should be roughly double the previous (with random factor)
      expect(timeouts[1]).to be > timeouts[0]
      expect(timeouts[2]).to be > timeouts[1]
      expect(timeouts[3]).to be > timeouts[2]
      expect(timeouts[4]).to be > timeouts[3]

      # Base timeout pattern: 2s, 4s, 8s, 16s, 32s (before random factor)
      expect(timeouts[0]).to be_between(2.0, 3.0) # 2 * (1.0..1.5)
      expect(timeouts[1]).to be_between(4.0, 6.0) # 4 * (1.0..1.5)
      expect(timeouts[2]).to be_between(8.0, 12.0) # 8 * (1.0..1.5)
    end

    it 'respects MAX_RETRANSMIT limit' do
      callback_called = false
      error_message = nil

      # Allow socket sends for retransmissions
      allow(socket).to receive(:send).with(message_data, 0, host, port)

      manager.send_confirmable(message_id, message_data, socket, host, port) do |_resp, err|
        callback_called = true
        error_message = err
      end

      # Manually trigger timeouts by manipulating the transmission
      pending = manager.instance_variable_get(:@pending)
      transmission = pending[message_id]

      # Simulate MAX_RETRANSMIT attempts
      (described_class::MAX_RETRANSMIT + 1).times do
        transmission.timeout_at = Time.now.to_f - 1
        sleep 0.2 # Allow retransmission loop to process
      end

      # Wait for callback
      sleep 0.5

      expect(callback_called).to be true
      expect(error_message).to include('Timeout')
      expect(manager.stats[:pending_count]).to eq(0)
    end
  end

  describe 'RFC 7252 §4.8 transmission parameters' do
    it 'uses correct ACK_TIMEOUT value' do
      expect(described_class::ACK_TIMEOUT).to eq(2.0)
    end

    it 'uses correct ACK_RANDOM_FACTOR value' do
      expect(described_class::ACK_RANDOM_FACTOR).to eq(1.5)
    end

    it 'uses correct MAX_RETRANSMIT value' do
      expect(described_class::MAX_RETRANSMIT).to eq(4)
    end
  end
end
