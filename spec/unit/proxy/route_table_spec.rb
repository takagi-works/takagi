# frozen_string_literal: true

require 'tempfile'

# Row 1 of .omo/plans/coap-proxy.md: the proxy configuration section and the
# prefix-to-backend route table built from it.
#
# Every example here is a PROOF for that row: on the pre-change tree neither
# `Takagi::Proxy::RouteTable` nor `Takagi.config.proxy` exists, so each one fails before the
# row's change. The nested-prefix, no-match, duplicate-prefix, self-route and `Takagi.config`
# reachability examples are the row's own acceptance criteria.
RSpec.describe Takagi::Proxy::RouteTable do
  def route(prefix, host: '127.0.0.1', port: 9001, **rest)
    { prefix: prefix, host: host, port: port }.merge(rest)
  end

  def build_table(routes, names: [], own_ports: [])
    described_class.new(routes: routes, names: names, own_ports: own_ports)
  end

  describe 'longest-prefix resolution' do
    let(:nested) do
      build_table([route('/'), route('/sensors', port: 9001), route('/sensors/temp', port: 9002)])
    end

    it 'resolves the longest matching prefix for nested prefixes (PROOF, row 1)' do
      match = nested.resolve('/sensors/temp/1')

      expect(match.route.prefix).to eq('/sensors/temp')
      expect(match.route.port).to eq(9002)
      expect(match.relative_path).to eq('/1')
    end

    it 'falls back to the shorter prefix for a path only it claims (PROOF, row 1)' do
      match = nested.resolve('/sensors/humidity')

      expect(match.route.prefix).to eq('/sensors')
      expect(match.relative_path).to eq('/humidity')
    end

    it 'keeps the whole path for a root route and yields / for the prefix itself (PROOF, row 1)' do
      expect(nested.resolve('/unrelated').relative_path).to eq('/unrelated')
      expect(nested.resolve('/sensors').route.prefix).to eq('/sensors')
      expect(nested.resolve('/sensors').relative_path).to eq('/')
    end

    it 'matches whole path segments only, so /sensor cannot capture /sensors (PROOF, row 1)' do
      table = build_table([route('/sensor')])

      expect(table.resolve('/sensors')).to be_nil
      expect(table.resolve('/sensor/1').relative_path).to eq('/1')
    end
  end

  describe 'a path no route claims' do
    it 'returns no backend rather than a wrong one (PROOF, row 1)' do
      table = build_table([route('/sensors', port: 9001), route('/admin', port: 9002)])

      expect(table.resolve('/actuators/lamp')).to be_nil
      expect(table.resolve('/sensors/temp')).not_to be_nil
    end

    it 'returns no backend from a table with no routes at all (PROOF, row 1)' do
      expect(build_table([]).resolve('/anything')).to be_nil
    end
  end

  describe 'route validation' do
    it 'raises naming the prefix when two routes claim the same prefix (PROOF, row 1)' do
      expect do
        build_table([route('/sensors', port: 9001), route('/sensors', port: 9002)])
      end.to raise_error(ArgumentError, %r{duplicate proxy route prefix: "/sensors"})
    end

    it 'treats a trailing slash as the same prefix (PROOF, row 1)' do
      expect { build_table([route('/sensors'), route('/sensors/')]) }
        .to raise_error(ArgumentError, %r{duplicate proxy route prefix: "/sensors"})
    end

    it 'rejects a relative or empty prefix (PROOF, row 1)' do
      expect { build_table([route('sensors')]) }.to raise_error(ArgumentError, /absolute/)
      expect { build_table([route('')]) }.to raise_error(ArgumentError, /absolute/)
    end

    it 'rejects a backend authority that is not well formed (PROOF, row 1)' do
      expect { build_table([route('/a', host: '')]) }.to raise_error(ArgumentError, /host/)
      expect { build_table([route('/a', port: 0)]) }.to raise_error(ArgumentError, /port/)
      expect { build_table([route('/a', port: 'http')]) }.to raise_error(ArgumentError, /port/)
    end

    it 'rejects an unknown outbound transport (PROOF, row 1)' do
      expect { build_table([route('/a', outbound: :sctp)]) }.to raise_error(ArgumentError, /outbound/)
    end

    it 'defaults a route outbound transport to the inbound one and honours an override (PROOF, row 1)' do
      table = build_table([route('/sensors'), route('/admin', outbound: 'tcp')])

      expect(table.resolve('/sensors/temp').outbound).to be_nil
      expect(table.resolve('/admin/users').outbound).to eq(:tcp)
    end
  end

  describe 'self-route rejection' do
    it 'raises, naming the route, when a route points at one of the proxy own names (PROOF, row 1)' do
      routes = [route('/self', host: '127.0.0.1', port: 5683)]

      expect { build_table(routes, names: ['127.0.0.1:5683']) }
        .to raise_error(ArgumentError, %r{/self -> 127\.0\.0\.1:5683})
    end

    it 'recognizes a bare own name on one of the proxy own ports (PROOF, row 1)' do
      routes = [route('/self', host: 'localhost', port: 5683)]

      expect { build_table(routes, names: ['localhost'], own_ports: [5683]) }
        .to raise_error(ArgumentError, /points at the proxy itself/)
    end

    it 'still resolves the same host on a different port: the port is part of the authority (PROOF, row 1)' do
      table = build_table([route('/sensor', host: 'localhost', port: 9000)],
                          names: ['localhost'], own_ports: [5683])

      expect(table.resolve('/sensor/1').route.port).to eq(9000)
    end
  end

  describe 'the proxy section of Takagi.config' do
    around do |example|
      previous_proxy = Takagi.config.proxy
      previous_port = Takagi.config.port
      example.run
    ensure
      Takagi.config.proxy = previous_proxy
      Takagi.config.port = previous_port
    end

    def load_proxy_config(yaml)
      file = Tempfile.new('takagi-proxy')
      file.write(yaml)
      file.flush
      Takagi.config.load_file(file.path)
      file.close!
    end

    it 'reads a written proxy section back off Takagi.config and resolves through it (PROOF, row 1)' do
      load_proxy_config <<~YAML
        port: 5683
        proxy:
          enabled: true
          names:
            - localhost
            - 127.0.0.1
          discovery: aggregate
          routes:
            - prefix: /sensors
              host: 127.0.0.1
              port: 9001
            - prefix: /admin
              host: 127.0.0.1
              port: 9002
              outbound: tcp
      YAML

      proxy = Takagi.config.proxy
      expect(proxy.enabled).to be(true)
      expect(proxy.names).to eq(%w[localhost 127.0.0.1])
      expect(proxy.discovery).to eq(:aggregate)
      expect(proxy.forward).to eq(:deny)
      expect(proxy.routes.map(&:prefix)).to eq(['/sensors', '/admin'])
      expect(proxy.routes.first.outbound).to be_nil
      expect(proxy.routes.last.outbound).to eq(:tcp)

      table = described_class.from_config(Takagi.config)
      match = table.resolve('/sensors/temp/1')
      expect(match.route.prefix).to eq('/sensors')
      expect(match.route.port).to eq(9001)
      expect(match.relative_path).to eq('/temp/1')
    end

    it 'rejects, through from_config, a route pointing at the configured port (PROOF, row 1)' do
      load_proxy_config <<~YAML
        port: 5683
        proxy:
          enabled: true
          names:
            - localhost
          routes:
            - prefix: /self
              host: localhost
              port: 5683
      YAML

      expect { described_class.from_config(Takagi.config) }
        .to raise_error(ArgumentError, /points at the proxy itself/)
    end

    it 'refuses to build the table from a proxy section that is disabled (PROOF, row 21)' do
      load_proxy_config <<~YAML
        proxy:
          enabled: false
          names:
            - localhost
          routes:
            - prefix: /sensors
              host: 127.0.0.1
              port: 9001
      YAML

      expect(Takagi.config.proxy.enabled).to be(false)
      expect { described_class.from_config(Takagi.config) }
        .to raise_error(ArgumentError, /proxy section is disabled/)
    end
  end

  describe 'transparent routes (strip_prefix)' do
    it 'forwards the whole path when strip_prefix is false (PROOF)' do
      match = build_table([route('/prefix', strip_prefix: false)]).resolve('/prefix/hello')

      expect(match.route.strip_prefix?).to be(false)
      expect(match.relative_path).to eq('/prefix/hello')
    end

    it 'strips the prefix by default (GUARD)' do
      match = build_table([route('/prefix')]).resolve('/prefix/hello')

      expect(match.route.strip_prefix?).to be(true)
      expect(match.relative_path).to eq('/hello')
    end

    it 'accepts a route with no prefix as the transparent catch-all (PROOF)' do
      match = build_table([{ host: '127.0.0.1', port: 9001 }]).resolve('/any/deep/path')

      expect(match.route.prefix).to eq('/')
      expect(match.route.strip_prefix?).to be(false)
      expect(match.relative_path).to eq('/any/deep/path')
    end

    it 'refuses a prefix-less route that asks to strip (PROOF)' do
      expect { build_table([{ host: '127.0.0.1', port: 9001, strip_prefix: true }]) }
        .to raise_error(ArgumentError, /without a prefix cannot strip/)
    end
  end
end
