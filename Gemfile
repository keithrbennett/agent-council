# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# Development dependencies
gem 'rake', '~> 13.4'
gem 'rspec', '~> 3.13'

# Pinned to a minor release so CI and the dev machines get the same cops even
# without a committed lockfile (NewCops is enabled); bump deliberately.
gem 'rubocop', '~> 1.92.0'
gem 'rubocop-rspec', '~> 3.10.0'

# Security auditing
gem 'bundler-audit', '~> 0.9', require: false
gem 'ruby_audit', '~> 3.1', require: false
