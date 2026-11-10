#!/usr/bin/env ruby
# frozen_string_literal: true

# Prints the desktop app version from app/pubspec.yaml, which Release Please
# updates and Flutter reads.
#
#   ruby script/app-version.rb          1.2.3
#   ruby script/app-version.rb build    the +build number, e.g. 7
#   ruby script/app-version.rb msix     1.2.3.0, the version msix:create derives
#
# Releases use plain MAJOR.MINOR.PATCH versions: Apple bundle versions and the
# Windows file version must be numeric, and MSIX has no pre-release ordering.

require 'yaml'

pubspec = File.expand_path('../app/pubspec.yaml', __dir__)
raw = YAML.safe_load_file(pubspec).fetch('version').to_s
match = /\A(\d+)\.(\d+)\.(\d+)\+(\d+)\z/.match(raw)
abort "app/pubspec.yaml version #{raw.inspect} must look like 1.2.3+4." unless match

version = match.captures.first(3).join('.')
case ARGV
when [] then puts version
when ['build'] then puts match[4]
when ['msix'] then puts "#{version}.0"
else abort 'usage: ruby script/app-version.rb [build|msix]'
end
