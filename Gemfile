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

# simplecov writes coverage/coverage.json, the file cov-loupe reads. Normal
# `bundle install` resolves it within the 1.x range. The "compat" job in
# .github/workflows/ci.yml sets SIMPLECOV_VERSION to run the suite against the
# oldest and newest 1.x releases, so an incompatible upstream release fails
# there rather than on main.
simplecov_pin = ENV.fetch('SIMPLECOV_VERSION', '')
gem 'simplecov', '>= 1.0', '< 2.0', *([simplecov_pin] unless simplecov_pin.empty?)

# simplecov-cobertura 4.x is the line that pairs with simplecov 1.x.
gem 'simplecov-cobertura', '~> 4.0'

# Security auditing
gem 'bundler-audit', '~> 0.9', require: false
gem 'ruby_audit', '~> 3.1', require: false
