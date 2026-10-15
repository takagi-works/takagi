# frozen_string_literal: true

require 'spec_helper'
require 'takagi/response_builder'

RSpec.describe Takagi::ResponseBuilder do
  let(:payload) { { temp: 25 } }

  def build_inbound(accept: nil, content_format: nil)
    double('Inbound', accept: accept, content_format: content_format)
  end

  describe '.respond' do
    let(:response_code) { Takagi::CoAP::Registries::Response::CONTENT }
    let(:content_option) { Takagi::CoAP::Registries::Option::CONTENT_FORMAT }
    let(:json_format) { Takagi::CoAP::Registries::ContentFormat::JSON }
    let(:cbor_format) { Takagi::CoAP::Registries::ContentFormat::CBOR }

    it 'uses forced format when supported' do
      inbound = build_inbound
      expect(inbound).to receive(:to_response).with(
        response_code,
        payload,
        options: { content_option => [cbor_format] }
      )

      described_class.respond(inbound, payload, force: cbor_format)
    end

    it 'uses Accept when supported and allowed' do
      inbound = build_inbound(accept: cbor_format)

      expect(inbound).to receive(:to_response).with(
        response_code,
        payload,
        options: { content_option => [cbor_format] }
      )

      described_class.respond(inbound, payload, formats: [json_format, cbor_format])
    end

    it 'returns 4.06 when Accept is unsupported' do
      inbound = build_inbound(accept: 999)
      not_acceptable = Takagi::CoAP::Registries::Response::NOT_ACCEPTABLE

      expect(inbound).to receive(:to_response).with(
        not_acceptable,
        { error: 'Not Acceptable' }
      )

      described_class.respond(inbound, payload, formats: [json_format, cbor_format])
    end

    it 'returns 4.15 when forced format is unsupported' do
      inbound = build_inbound
      unsupported = Takagi::CoAP::Registries::Response::UNSUPPORTED_CONTENT_FORMAT

      expect(inbound).to receive(:to_response).with(
        unsupported,
        { error: 'Unsupported Content-Format' }
      )

      described_class.respond(inbound, payload, force: 999)
    end

    it 'defaults to router content-format when none specified' do
      inbound = build_inbound
      default_format = Takagi::Router::DEFAULT_CONTENT_FORMAT

      expect(inbound).to receive(:to_response).with(
        response_code,
        payload,
        options: { content_option => [default_format] }
      )

      described_class.respond(inbound, payload)
    end

    it 'uses first supported format when Accept is absent' do
      inbound = build_inbound

      expect(inbound).to receive(:to_response).with(
        response_code,
        payload,
        options: { content_option => [cbor_format] }
      )

      described_class.respond(inbound, payload, formats: [cbor_format, json_format])
    end
  end
end
