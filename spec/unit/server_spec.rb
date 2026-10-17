# frozen_string_literal: true

require "socket"

RSpec.describe Takagi::Server::Udp do
  it "starts and shuts down cleanly" do
    server = Takagi::Server::Udp.new(port: 0)

    thread = Thread.new { server.run! }
    sleep 0.1
  ensure
    server.shutdown!
    thread&.join
  end
end
