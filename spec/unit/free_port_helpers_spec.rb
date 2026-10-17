# frozen_string_literal: true

# Row 25 of .omo/plans/tcp-multi-worker.md: the port helper's contract, pinned.
#
# `find_free_port` handed out a bare NUMBER that nothing held, so a competing bind could take it
# and the caller died with `Errno::EADDRINUSE` - the flake registered as row 18 and still live in
# its 18 call sites. The suite no longer takes numbers: `free_port_socket` hands out the SOCKET
# that keeps the port bound, and every spec that needs its own SERVER binds `port: 0` and reads
# the earned port back off the server's own socket (`bound_port_of`), which holds it from
# creation.
RSpec.describe 'race-free port helpers (plan row 25)' do
  describe '#free_port_socket' do
    it 'returns a socket that still holds the port it probed, so no competing bind can take it (PROOF)' do
      socket = free_port_socket
      port = socket.addr[1]

      expect(port).to be > 0

      # A competing bind in the SAME namespace is refused, because this process still holds the
      # port. That is exactly what the old helper could not promise: it closed its probe first.
      competing = UDPSocket.new
      expect { competing.bind('127.0.0.1', port) }.to raise_error(Errno::EADDRINUSE)
    ensure
      competing&.close
      socket&.close
    end

    it 'lets the kernel choose the port in the ordinary case (GUARD)' do
      first = free_port_socket
      second = free_port_socket

      expect(first.addr[1]).to be > 0
      expect(second.addr[1]).to be > 0
    ensure
      first&.close
      second&.close
    end

    # N4: the helper returns a FIXED port when ephemeral probing is disabled - the historical
    # `RSPEC_DISABLE_UDP` contract, pinned here so the branch cannot be lost silently.
    it 'binds the fixed RSPEC_DEFAULT_PORT when ephemeral probing is disabled (PROOF)' do
      probe = free_port_socket
      fixed_port = probe.addr[1]
      probe.close

      socket = with_env('RSPEC_DISABLE_UDP' => '1', 'RSPEC_DEFAULT_PORT' => fixed_port.to_s) do
        expect(free_port_fixed_port).to eq(fixed_port)
        free_port_socket
      end

      expect(socket.addr[1]).to eq(fixed_port)
    ensure
      socket&.close
    end

    it 'defaults the fixed port to 5683 when RSPEC_DEFAULT_PORT is not given (GUARD)' do
      fixed = with_env('RSPEC_DISABLE_UDP' => '1', 'RSPEC_DEFAULT_PORT' => nil) do
        free_port_fixed_port
      end

      expect(fixed).to eq(5683)
    end

    it 'asks the kernel to choose when ephemeral probing is enabled (GUARD)' do
      fixed = with_env('RSPEC_DISABLE_UDP' => nil, 'RSPEC_DEFAULT_PORT' => nil) do
        free_port_fixed_port
      end

      expect(fixed).to be_nil
    end
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
