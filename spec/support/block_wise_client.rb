# frozen_string_literal: true

require 'digest'

# Routes shared by the client block-wise end-to-end specs
# (spec/unit/takagi_client_spec.rb, spec/unit/tcp_client_spec.rb,
# spec/unit/unified_client_spec.rb): a representation larger than one block and an
# echo route that reports the body the handler actually received.
class ClientBlockWiseSpecApp < Takagi::Base
  BIG_BLOB = { blob: 'x' * 4096 }.freeze

  get '/client-block-wise/big' do
    BIG_BLOB
  end

  post '/client-block-wise/echo' do |req|
    body = req.payload.to_s
    { size: body.bytesize, digest: Digest::SHA256.hexdigest(body) }
  end
end

# Builds the byte-exact representation `/client-block-wise/big` serves, so specs can
# compare a reassembled payload against the server's own output rather than a re-typed string.
module BlockWiseClientExpectation
  def big_representation
    uri = URI('coap://localhost/client-block-wise/big')
    request = Takagi::Message::Request.new(method: :get, uri: uri, token: ''.b)
    Takagi::ResponseBuilder.respond(Takagi::Message::Inbound.new(request.to_bytes),
                                    ClientBlockWiseSpecApp::BIG_BLOB).payload
  end
end

RSpec.configure { |config| config.include BlockWiseClientExpectation }
