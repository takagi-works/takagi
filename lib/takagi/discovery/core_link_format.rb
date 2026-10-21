# frozen_string_literal: true

require 'uri'

module Takagi
  module Discovery
    # Builds CoRE Link Format payloads as defined in RFC 6690.
    class CoreLinkFormat
      CONTENT_FORMAT = 40

      def self.generate(router:, request: nil)
        query = request&.uri&.query
        new(router, query).generate
      end

      # Formats already-resolved entries as one CoRE Link Format document (RFC 6690 2): the same
      # entry shape `generate` produces, without the config-driven server entry.
      #
      # @param entries [Array<#path, #metadata>]
      # @return [String]
      def self.for_entries(entries)
        new(nil, nil).document(entries)
      end

      # One entry (RFC 6690 2 `link-value`) as the writer emits it: a URI-Reference, a quoted
      # string, or anything that is neither a comma nor one of those - a comma is the separator.
      ENTRY = /(?:<[^>]*>|"(?:\\.|[^"\\])*"|[^,])+/

      # Splits a CoRE Link Format document back into its entries (RFC 6690 2), the inverse of
      # `for_entries`/`document`. A comma ends a description only outside a URI-Reference and
      # outside a quoted string, where the RFC allows one to appear without ending anything:
      # "commas can also occur in quoted strings and URIs but do not end a description". An empty
      # segment is not a link-value, so a blank document yields no entry.
      #
      # @param document [String]
      # @return [Array<String>]
      def self.split_entries(document)
        document.to_s.scan(ENTRY)
      end

      def initialize(router, raw_query)
        @router = router
        @query = parse_query(raw_query)
      end

      def generate
        resources = router.link_format_entries
        server_entry = server_link_entry
        resources << server_entry if server_entry
        document(resources)
      end

      # @param entries [Array<#path, #metadata>]
      # @return [String]
      def document(entries)
        filtered = filter_resources(entries.reject { |entry| entry.path == '/.well-known/core' })
        filtered.map { |entry| format_entry(entry) }.join(',')
      end

      private

      attr_reader :router, :query

      def parse_query(raw_query)
        return {} if raw_query.nil? || raw_query.empty?

        URI.decode_www_form(raw_query).each_with_object(Hash.new { |h, k| h[k] = [] }) do |(key, value), acc|
          acc[key] << (value || '')
        end
      end

      def filter_resources(resources)
        return resources if query.empty?

        resources.select do |entry|
          query.all? { |key, values| matches_filter?(entry, key, values) }
        end
      end

      def matches_filter?(entry, key, values)
        case key
        when 'rt' then matches_list_attribute?(entry, :rt, values)
        when 'if' then matches_list_attribute?(entry, :if, values)
        when 'ct' then matches_numeric_attribute?(entry, :ct, values)
        when 'title' then matches_string_attribute?(entry, :title, values)
        when 'sz' then matches_numeric_attribute?(entry, :sz, values)
        when 'obs' then entry.metadata[:obs]
        when 'href' then values.any? { |val| entry.path == val }
        else false
        end
      end

      def matches_list_attribute?(entry, attribute, values)
        Array(entry.metadata[attribute]).any? { |item| values.include?(item.to_s) }
      end

      def matches_numeric_attribute?(entry, attribute, values)
        metadata_value = entry.metadata[attribute]
        metadata_value && values.any? { |val| metadata_value.to_i == val.to_i }
      end

      def matches_string_attribute?(entry, attribute, values)
        metadata_value = entry.metadata[attribute]
        metadata_value && values.include?(metadata_value.to_s)
      end

      def format_entry(entry)
        attributes = link_attributes_for(entry)
        "<#{normalize_path(entry.path)}>#{attributes}"
      end

      def normalize_path(path)
        path
      end

      def link_attributes_for(entry)
        metadata = entry.metadata

        attrs = []
        append_attribute(attrs, 'rt', metadata[:rt]) if metadata[:rt]
        append_attribute(attrs, 'if', metadata[:if]) if metadata[:if]
        append_numeric_attribute(attrs, 'ct', metadata[:ct]) if metadata.key?(:ct)
        append_numeric_attribute(attrs, 'sz', metadata[:sz]) if metadata.key?(:sz)
        append_attribute(attrs, 'title', metadata[:title]) if metadata[:title]
        attrs << ';obs' if metadata[:obs]
        join_attributes(attrs)
      end

      def append_attribute(attrs, name, value)
        return if value.nil?

        if value.is_a?(Array)
          value.each { |single| attrs << %(;#{name}="#{single}") }
        else
          attrs << %(;#{name}="#{value}")
        end
      end

      def append_numeric_attribute(attrs, name, value)
        return if value.nil?

        attrs << %(;#{name}=#{value})
      end

      def join_attributes(attrs)
        attrs.join
      end

      def server_link_entry
        name = Takagi.config.server_name
        return if name.nil? || name.empty?

        Takagi::Router::RouteEntry.new(
          method: 'SERVER',
          path: '/',
          block: nil,
          metadata: {
            rt: 'core.server',
            if: 'takagi.meta',
            ct: Takagi::Router::DEFAULT_CONTENT_FORMAT,
            title: name
          },
          receiver: nil
        )
      end
    end
  end
end
