# frozen_string_literal: true

RSpec.describe Takagi::Client::Response do
  # Helper to create a mock CoAP response
  def mock_response(code:, payload: 'test payload', content_format: nil)
    options = content_format ? { Takagi::CoAP::Registries::Option::CONTENT_FORMAT => [content_format] } : {}
    # Convert numeric code to the string format expected by Outbound
    code_string = Takagi::CoAP::CodeHelpers.to_string(code)
    outbound = Takagi::Message::Outbound.new(
      code: code_string,
      payload: payload,
      token: 'test',
      message_id: 1,
      type: 2,
      options: options
    )
    outbound.to_bytes
  end

  describe '#initialize' do
    it 'wraps raw response data' do
      raw_data = mock_response(code: 69) # 2.05 Content
      response = described_class.new(raw_data)

      expect(response.raw_data).to eq(raw_data)
      expect(response.code).to eq(69)
      expect(response.payload).to eq('test payload')
    end
  end

  describe 'success checking' do
    it 'identifies successful responses (2.xx)' do
      response = described_class.new(mock_response(code: 69)) # 2.05
      expect(response.success?).to be true
      expect(response.error?).to be false
      expect(response.client_error?).to be false
      expect(response.server_error?).to be false
    end

    it 'identifies client errors (4.xx)' do
      response = described_class.new(mock_response(code: 132)) # 4.04
      expect(response.success?).to be false
      expect(response.error?).to be true
      expect(response.client_error?).to be true
      expect(response.server_error?).to be false
    end

    it 'identifies server errors (5.xx)' do
      response = described_class.new(mock_response(code: 160)) # 5.00
      expect(response.success?).to be false
      expect(response.error?).to be true
      expect(response.client_error?).to be false
      expect(response.server_error?).to be true
    end
  end

  describe 'specific code checking' do
    it 'checks for 2.05 Content (ok)' do
      response = described_class.new(mock_response(code: 69))
      expect(response.content?).to be true
      expect(response.ok?).to be true
    end

    it 'checks for 2.01 Created' do
      response = described_class.new(mock_response(code: 65))
      expect(response.created?).to be true
    end

    it 'checks for 2.04 Changed' do
      response = described_class.new(mock_response(code: 68))
      expect(response.changed?).to be true
    end

    it 'checks for 4.04 Not Found' do
      response = described_class.new(mock_response(code: 132))
      expect(response.not_found?).to be true
    end

    it 'checks for 4.00 Bad Request' do
      response = described_class.new(mock_response(code: 128))
      expect(response.bad_request?).to be true
    end

    it 'checks for 5.00 Internal Server Error' do
      response = described_class.new(mock_response(code: 160))
      expect(response.internal_server_error?).to be true
    end
  end

  describe 'JSON handling' do
    it 'parses JSON payload' do
      json_payload = JSON.generate({ temperature: 25, humidity: 60 })
      response = described_class.new(mock_response(code: 69, payload: json_payload, content_format: 50))

      json_data = response.data
      expect(json_data).to be_a(Hash)
      expect(json_data['temperature']).to eq(25)
      expect(json_data['humidity']).to eq(60)
    end

    it 'returns nil for invalid JSON' do
      response = described_class.new(mock_response(code: 69, payload: 'not json'))
      expect(response.data).to be_nil
    end

    it 'detects JSON content-format' do
      response_json = described_class.new(mock_response(code: 69, content_format: 50))
      response_plain = described_class.new(mock_response(code: 69, content_format: 0))

      expect(response_json.json?).to be true
      expect(response_plain.json?).to be false
    end
  end

  describe 'content-format' do
    it 'returns content-format value' do
      response = described_class.new(mock_response(code: 69, content_format: 50))
      expect(response.content_format).to eq(50)
    end

    it 'returns nil when no content-format' do
      response = described_class.new(mock_response(code: 69))
      expect(response.content_format).to be_nil
    end
  end

  describe '#to_s and #inspect' do
    it 'provides readable string representation' do
      response = described_class.new(mock_response(code: 69, payload: 'Hello'))

      expect(response.to_s).to include('2.05')
      expect(response.to_s).to include('payload_size=5')

      expect(response.inspect).to include('2.05')
      expect(response.inspect).to include('success=true')
      expect(response.inspect).to include('Hello')
    end

    it 'truncates long payloads in inspect' do
      long_payload = 'x' * 100
      response = described_class.new(mock_response(code: 69, payload: long_payload))

      expect(response.inspect.length).to be < 150
      expect(response.inspect).to include('...')
    end
  end
end
