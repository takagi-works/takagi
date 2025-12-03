# frozen_string_literal: true

RSpec.describe 'CoAP Registries' do
  describe Takagi::CoAP::Registries::Method do
    it 'provides standard method constants' do
      expect(Takagi::CoAP::Registries::Method::GET).to eq(1)
      expect(Takagi::CoAP::Registries::Method::POST).to eq(2)
      expect(Takagi::CoAP::Registries::Method::PUT).to eq(3)
      expect(Takagi::CoAP::Registries::Method::DELETE).to eq(4)
    end

    it 'provides method names' do
      expect(Takagi::CoAP::Registries::Method.name_for(1)).to eq('GET')
      expect(Takagi::CoAP::Registries::Method.name_for(2)).to eq('POST')
    end

    it 'validates method codes' do
      expect(Takagi::CoAP::Registries::Method.valid?(1)).to be true
      expect(Takagi::CoAP::Registries::Method.valid?(99)).to be false
    end

    it 'allows plugins to register custom methods' do
      Takagi::CoAP::Registries::Method.register(5, 'FETCH', :fetch, rfc: 'RFC 8132')
      expect(Takagi::CoAP::Registries::Method::FETCH).to eq(5)
      expect(Takagi::CoAP::Registries::Method.name_for(5)).to eq('FETCH')
    ensure
      # Cleanup
      Takagi::CoAP::Registries::Method.instance_variable_get(:@registry).delete(5)
      Takagi::CoAP::Registries::Method.send(:remove_const, :FETCH) if Takagi::CoAP::Registries::Method.const_defined?(:FETCH, false)
    end
  end

  describe Takagi::CoAP::Registries::Response do
    it 'provides standard response constants' do
      expect(Takagi::CoAP::Registries::Response::CONTENT).to eq(69)
      expect(Takagi::CoAP::Registries::Response::NOT_FOUND).to eq(132)
      expect(Takagi::CoAP::Registries::Response::INTERNAL_SERVER_ERROR).to eq(160)
    end

    it 'provides response names with dotted notation' do
      expect(Takagi::CoAP::Registries::Response.name_for(69)).to eq('2.05 Content')
      expect(Takagi::CoAP::Registries::Response.name_for(132)).to eq('4.04 Not Found')
    end

    it 'identifies success codes' do
      expect(Takagi::CoAP::Registries::Response.success?(69)).to be true
      expect(Takagi::CoAP::Registries::Response.success?(132)).to be false
    end

    it 'identifies client errors' do
      expect(Takagi::CoAP::Registries::Response.client_error?(132)).to be true
      expect(Takagi::CoAP::Registries::Response.client_error?(69)).to be false
    end

    it 'identifies server errors' do
      expect(Takagi::CoAP::Registries::Response.server_error?(160)).to be true
      expect(Takagi::CoAP::Registries::Response.server_error?(69)).to be false
    end

    it 'identifies any errors' do
      expect(Takagi::CoAP::Registries::Response.error?(132)).to be true
      expect(Takagi::CoAP::Registries::Response.error?(160)).to be true
      expect(Takagi::CoAP::Registries::Response.error?(69)).to be false
    end

    it 'allows plugins to register custom response codes' do
      Takagi::CoAP::Registries::Response.register(231, '7.07 Custom', :custom)
      expect(Takagi::CoAP::Registries::Response::CUSTOM).to eq(231)
      expect(Takagi::CoAP::Registries::Response.name_for(231)).to eq('7.07 Custom')
    ensure
      # Cleanup
      Takagi::CoAP::Registries::Response.instance_variable_get(:@registry).delete(231)
      Takagi::CoAP::Registries::Response.send(:remove_const, :CUSTOM) if Takagi::CoAP::Registries::Response.const_defined?(:CUSTOM, false)
    end
  end

  describe Takagi::CoAP::Registries::Option do
    it 'provides standard option constants' do
      expect(Takagi::CoAP::Registries::Option::URI_PATH).to eq(11)
      expect(Takagi::CoAP::Registries::Option::CONTENT_FORMAT).to eq(12)
      expect(Takagi::CoAP::Registries::Option::URI_QUERY).to eq(15)
    end

    it 'provides option names' do
      expect(Takagi::CoAP::Registries::Option.name_for(11)).to eq('Uri-Path')
      expect(Takagi::CoAP::Registries::Option.name_for(12)).to eq('Content-Format')
    end

    it 'identifies critical options' do
      expect(Takagi::CoAP::Registries::Option.critical?(11)).to be true  # Uri-Path (odd)
      expect(Takagi::CoAP::Registries::Option.critical?(12)).to be false # Content-Format (even)
    end

    it 'allows plugins to register custom options' do
      Takagi::CoAP::Registries::Option.register(65000, 'Custom-Option', :custom_option)
      expect(Takagi::CoAP::Registries::Option::CUSTOM_OPTION).to eq(65000)
      expect(Takagi::CoAP::Registries::Option.name_for(65000)).to eq('Custom-Option')
    ensure
      # Cleanup
      Takagi::CoAP::Registries::Option.instance_variable_get(:@registry).delete(65000)
      Takagi::CoAP::Registries::Option.send(:remove_const, :CUSTOM_OPTION) if Takagi::CoAP::Registries::Option.const_defined?(:CUSTOM_OPTION, false)
    end
  end

  describe Takagi::CoAP::Registries::ContentFormat do
    it 'provides standard content-format constants' do
      expect(Takagi::CoAP::Registries::ContentFormat::TEXT_PLAIN).to eq(0)
      expect(Takagi::CoAP::Registries::ContentFormat::JSON).to eq(50)
      expect(Takagi::CoAP::Registries::ContentFormat::CBOR).to eq(60)
    end

    it 'provides MIME types' do
      expect(Takagi::CoAP::Registries::ContentFormat.mime_type_for(50)).to eq('application/json')
      expect(Takagi::CoAP::Registries::ContentFormat.mime_type_for(0)).to eq('text/plain')
    end

    it 'identifies JSON formats' do
      expect(Takagi::CoAP::Registries::ContentFormat.json?(50)).to be true
      expect(Takagi::CoAP::Registries::ContentFormat.json?(0)).to be false
    end

    it 'identifies text formats' do
      expect(Takagi::CoAP::Registries::ContentFormat.text?(0)).to be true
      expect(Takagi::CoAP::Registries::ContentFormat.text?(50)).to be false
    end

    it 'allows plugins to register custom formats' do
      Takagi::CoAP::Registries::ContentFormat.register(65001, 'application/custom', :custom)
      expect(Takagi::CoAP::Registries::ContentFormat::CUSTOM).to eq(65001)
      expect(Takagi::CoAP::Registries::ContentFormat.mime_type_for(65001)).to eq('application/custom')
    ensure
      # Cleanup
      Takagi::CoAP::Registries::ContentFormat.instance_variable_get(:@registry).delete(65001)
      Takagi::CoAP::Registries::ContentFormat.send(:remove_const, :CUSTOM) if Takagi::CoAP::Registries::ContentFormat.const_defined?(:CUSTOM, false)
    end
  end

  describe Takagi::CoAP::Registries::MessageType do
    it 'provides standard message type constants' do
      expect(Takagi::CoAP::Registries::MessageType::CONFIRMABLE).to eq(0)
      expect(Takagi::CoAP::Registries::MessageType::NON_CONFIRMABLE).to eq(1)
      expect(Takagi::CoAP::Registries::MessageType::ACKNOWLEDGEMENT).to eq(2)
      expect(Takagi::CoAP::Registries::MessageType::RESET).to eq(3)
    end

    it 'provides convenient aliases' do
      expect(Takagi::CoAP::Registries::MessageType::CON).to eq(0)
      expect(Takagi::CoAP::Registries::MessageType::NON).to eq(1)
      expect(Takagi::CoAP::Registries::MessageType::ACK).to eq(2)
      expect(Takagi::CoAP::Registries::MessageType::RST).to eq(3)
    end

    it 'provides type checking methods' do
      expect(Takagi::CoAP::Registries::MessageType.confirmable?(0)).to be true
      expect(Takagi::CoAP::Registries::MessageType.ack?(2)).to be true
      expect(Takagi::CoAP::Registries::MessageType.reset?(3)).to be true
    end
  end

  describe Takagi::CoAP::CodeHelpers do
    describe '.to_string' do
      it 'converts method codes to strings' do
        expect(Takagi::CoAP::CodeHelpers.to_string(1)).to eq('GET')
        expect(Takagi::CoAP::CodeHelpers.to_string(:post)).to eq('POST')
      end

      it 'converts response codes to strings' do
        expect(Takagi::CoAP::CodeHelpers.to_string(69)).to eq('2.05 Content')
        expect(Takagi::CoAP::CodeHelpers.to_string(:not_found)).to eq('4.04 Not Found')
      end

      it 'converts dotted strings' do
        expect(Takagi::CoAP::CodeHelpers.to_string('2.05')).to eq('2.05 Content')
      end
    end

    describe '.to_numeric' do
      it 'converts symbols to numeric codes' do
        expect(Takagi::CoAP::CodeHelpers.to_numeric(:get)).to eq(1)
        expect(Takagi::CoAP::CodeHelpers.to_numeric(:content)).to eq(69)
      end

      it 'converts dotted strings to numeric codes' do
        expect(Takagi::CoAP::CodeHelpers.to_numeric('2.05')).to eq(69)
        expect(Takagi::CoAP::CodeHelpers.to_numeric('4.04')).to eq(132)
      end

      it 'passes through integers' do
        expect(Takagi::CoAP::CodeHelpers.to_numeric(69)).to eq(69)
      end
    end

    describe '.numeric_to_string' do
      it 'converts to dotted notation' do
        expect(Takagi::CoAP::CodeHelpers.numeric_to_string(69)).to eq('2.05')
        expect(Takagi::CoAP::CodeHelpers.numeric_to_string(132)).to eq('4.04')
      end
    end

    describe '.string_to_numeric' do
      it 'converts from dotted notation' do
        expect(Takagi::CoAP::CodeHelpers.string_to_numeric('2.05')).to eq(69)
        expect(Takagi::CoAP::CodeHelpers.string_to_numeric('4.04')).to eq(132)
      end
    end

    describe 'status checking' do
      it 'identifies success codes' do
        expect(Takagi::CoAP::CodeHelpers.success?(69)).to be true
        expect(Takagi::CoAP::CodeHelpers.success?('2.05')).to be true
        expect(Takagi::CoAP::CodeHelpers.success?(:content)).to be true
      end

      it 'identifies error codes' do
        expect(Takagi::CoAP::CodeHelpers.error?(132)).to be true
        expect(Takagi::CoAP::CodeHelpers.client_error?('4.04')).to be true
        expect(Takagi::CoAP::CodeHelpers.server_error?(160)).to be true
      end
    end

    describe '.lookup' do
      it 'provides comprehensive code information' do
        info = Takagi::CoAP::CodeHelpers.lookup(69)
        expect(info[:value]).to eq(69)
        expect(info[:string]).to eq('2.05')
        expect(info[:name]).to eq('2.05 Content')
        expect(info[:type]).to eq(:response)
      end
    end
  end
end
