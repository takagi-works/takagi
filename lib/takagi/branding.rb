# frozen_string_literal: true

module Takagi
  # Branding and visual identity for Takagi
  module Branding
    # Japanese wave symbol - represents observables, events, and flow
    WAVE = '波'
    LOGO = "[#{WAVE}]"

    # Styled logo with name
    LOGO_WITH_NAME = "#{LOGO} Takagi"

    # ASCII art banner for server startup
    BANNER = <<~BANNER

        ╔═══════════════════════════════════╗
        ║                                   ║
        ║         [#{WAVE}] T A K A G I          ║
        ║                                   ║
        ║     CoAP Framework for Ruby       ║
        ║                                   ║
        ╚═══════════════════════════════════╝

    BANNER

    # Compact banner for constrained terminals
    COMPACT_BANNER = <<~BANNER
      ═══════════════════════════════
        [#{WAVE}] Takagi CoAP Framework
      ═══════════════════════════════
    BANNER

    # Wave pattern decorations
    WAVE_LINE = '〜' * 20

    # Prefix for log messages
    # @param message [String] Log message
    # @return [String] Message with logo prefix
    def self.log(message)
      "#{LOGO} #{message}"
    end

    # Print startup banner
    # @param compact [Boolean] Use compact banner for smaller terminals
    def self.print_banner(compact: false)
      puts compact ? COMPACT_BANNER : BANNER
    end

    # Print version info
    # @param version [String] Version string
    def self.print_version(version)
      puts "#{LOGO_WITH_NAME} v#{version}"
    end

    # Styled section header
    # @param title [String] Section title
    # @return [String] Styled header
    def self.section(title)
      <<~SECTION

        #{WAVE_LINE}
        #{LOGO} #{title}
        #{WAVE_LINE}
      SECTION
    end

    # Error prefix with wave
    # @param message [String] Error message
    # @return [String] Styled error
    def self.error(message)
      "#{LOGO} ERROR: #{message}"
    end

    # Success prefix with wave
    # @param message [String] Success message
    # @return [String] Styled success
    def self.success(message)
      "#{LOGO} ✓ #{message}"
    end

    # Info prefix with wave
    # @param message [String] Info message
    # @return [String] Styled info
    def self.info(message)
      "#{LOGO} #{message}"
    end
  end
end
