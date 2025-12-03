# frozen_string_literal: true

# Code coverage tracking
require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/examples/'
  add_group 'Core', 'lib/takagi/core'
  add_group 'Server', 'lib/takagi/server'
  add_group 'Message', 'lib/takagi/message'
  add_group 'Network', 'lib/takagi/network'
  add_group 'EventBus', 'lib/takagi/event_bus'
  add_group 'Observer', 'lib/takagi/observer'
  add_group 'Observable', 'lib/takagi/observable'
  add_group 'Controllers', 'lib/takagi/controller'
  add_group 'Application', 'lib/takagi/application'
  add_group 'CoAP', 'lib/takagi/coap'
  add_group 'Other', 'lib/takagi'
end

require "takagi"

def find_free_port
  return (ENV['RSPEC_DEFAULT_PORT'] || 5683).to_i if ENV['RSPEC_DISABLE_UDP']

  socket = UDPSocket.new
  socket.bind("127.0.0.1", 0)
  port = socket.addr[1]
  socket.close
  port
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].sort.each { |file| require file }

  def send_coap_request(type, method, path, payload = nil, token: ''.b, message_id: rand(0..0xFFFF), query: nil, options: {})
    raise ArgumentError, 'CoAP tokens must be 8 bytes or fewer' if token.bytesize > 8

    type_code = case type
                when :con then 0b00
                when :non then 0b01
                when :ack then 0b10
                when :rst then 0b11
                else 0b00
                end

    method_code = case method
                  when :get then 1
                  when :post then 2
                  when :put then 3
                  when :delete then 4
                  else 0
                  end

    token = token.to_s.b
    token_length = token.bytesize
    version_type_token = (0b01 << 6) | (type_code << 4) | token_length

    header = [version_type_token, method_code, (message_id >> 8) & 0xFF, message_id & 0xFF].pack("C*")
    option_entries = build_option_entries(path, query, options)
    packet = header + token + encode_options(option_entries)

    if payload
      payload = payload.to_s.b
      packet += "\xFF".b + payload
    end

    @client.send(packet, 0, *@server_address)
    response, = @client.recvfrom(1024)
    response
  end

  def build_option_entries(path, query, options)
    entries = []
    path_segments = path.split('/').reject(&:empty?)
    path_segments.each { |segment| entries << [11, segment] }

    if query
      queries = case query
                when String then query.split('&')
                when Hash
                  query.flat_map { |key, value| Array(value).map { |val| "#{key}=#{val}" } }
                else
                  []
                end
      queries.each { |segment| entries << [15, segment] }
    end

    options.each do |number, value|
      Array(value).each { |val| entries << [Integer(number), val] }
    end

    entries
  end

  def encode_options(entries)
    last_option_number = 0
    encoded = ''.b

    entries.each_with_index.sort_by { |(number, _value), index| [number, index] }.each do |(number, value), _index|
      encoded_value = case value
                      when Integer
                        encode_integer_option_value(value)
                      else
                        value.to_s.b
                      end

      delta = number - last_option_number
      delta_nibble, delta_extension = encode_option_header_value(delta)
      length_nibble, length_extension = encode_option_header_value(encoded_value.bytesize)

      option_byte = (delta_nibble << 4) | length_nibble
      encoded << option_byte.chr
      encoded << delta_extension if delta_extension
      encoded << length_extension if length_extension
      encoded << encoded_value

      last_option_number = number
    end

    encoded
  end

  def encode_option_header_value(value)
    case value
    when 0..12
      [value, nil]
    when 13..268
      [13, [value - 13].pack('C')]
    when 269..65_804
      [14, [value - 269].pack('n')]
    else
      raise ArgumentError, 'Option value too large'
    end
  end

  def encode_integer_option_value(value)
    return [value].pack('C') if value <= 0xFF
    return [value].pack('n') if value <= 0xFFFF

    [value].pack('N')
  end
end
