# frozen_string_literal: true

# Row 18 of .omo/plans/coap-proxy.md: the reader half of the CoRE Link Format shape. RFC 6690 2:
# "commas can also occur in quoted strings and URIs but do not end a description".
RSpec.describe Takagi::Discovery::CoreLinkFormat do
  describe '.split_entries' do
    it 'splits plain descriptions on their separating commas' do
      expect(described_class.split_entries('</a>;rt="x",</b>;obs')).to eq(['</a>;rt="x"', '</b>;obs'])
    end

    it 'keeps a comma inside a quoted attribute value' do
      expect(described_class.split_entries('</a>;title="a,b",</b>')).to eq(['</a>;title="a,b"', '</b>'])
    end

    it 'keeps a comma inside a URI-Reference' do
      expect(described_class.split_entries('<coap://host/a,b>,</b>')).to eq(['<coap://host/a,b>', '</b>'])
    end

    it 'round-trips what the writer emits for an attribute value carrying a comma' do
      entry = Takagi::Router::RouteEntry.new(method: 'GET', path: '/x', block: nil,
                                             metadata: { rt: 'a,b', title: 't, t' })

      expect(described_class.split_entries(described_class.for_entries([entry])))
        .to eq(['</x>;rt="a,b";title="t, t"'])
    end

    it 'yields no entry for a blank document' do
      expect(described_class.split_entries('')).to eq([])
    end
  end
end
