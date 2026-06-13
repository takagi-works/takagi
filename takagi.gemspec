# frozen_string_literal: true

require_relative 'lib/takagi/version'

# Compute files at the top level so the Gem::Specification block can
# reference it (the block runs in instance context, not top-level, so
# a top-level `def gem_files` is not visible inside `spec.files =`).
FILES = Dir.chdir(__dir__) do
  `git ls-files -z`.split("\x0").reject do |file|
    (File.expand_path(file) == __FILE__) ||
      file.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
  end
end

HOMEPAGE = 'https://github.com/takagi-works/takagi'

Gem::Specification.new do |spec|
  spec.name = 'takagi'
  spec.version = Takagi::VERSION
  spec.authors = ['Dominik Matoulek']
  spec.email = ['domitea@gmail.com']

  spec.summary = 'Lightweight CoAP framework for Ruby'
  spec.description = 'Sinatra-like framework for CoAP and IoT messaging.'
  spec.homepage = HOMEPAGE
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['allowed_push_host'] ||= 'https://rubygems.org'

  spec.metadata['homepage_uri']    = HOMEPAGE
  spec.metadata['source_code_uri'] = "#{HOMEPAGE}.git"
  spec.metadata['changelog_uri']   = "#{HOMEPAGE}/blob/master/CHANGELOG.md"

  spec.files = FILES
  spec.bindir = 'bin'
  spec.executables = ['takagi-dev']
  spec.require_paths = ['lib']

  spec.add_dependency 'rack', '~> 2.0'
  spec.add_dependency 'zeitwerk', '~> 2.0'

  spec.add_development_dependency 'rspec', '~> 3.0'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
