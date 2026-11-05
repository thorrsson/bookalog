#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

abort 'macOS disk-image packaging requires a macOS host.' unless RbConfig::CONFIG.fetch('host_os').include?('darwin')
root = File.expand_path('..', __dir__)
bundle = File.join(root, 'app/build/macos/Build/Products/Release/Bookalog Catalog.app')
output = File.join(root, '.cache/desktop')
image = File.join(output, 'bookalog-macos-unsigned.dmg')
abort 'Build the macOS app before packaging it.' unless File.directory?(bundle)
FileUtils.mkdir_p(output)

def run!(*command)
  abort "Packaging command failed: #{command.first}" unless system(*command)
end

stage = Dir.mktmpdir('macos-package-', output)
layout = File.join(stage, 'layout')
mount = File.join(stage, 'mount')
FileUtils.mkdir_p([layout, mount])
begin
  run!('ditto', bundle, File.join(layout, 'Bookalog Catalog.app'))
  File.symlink('/Applications', File.join(layout, 'Applications'))
  run!('hdiutil', 'create', '-ov', '-fs', 'HFS+', '-format', 'UDZO',
       '-volname', 'Bookalog Catalog', '-srcfolder', layout, image)
  run!('hdiutil', 'verify', image)
  run!('hdiutil', 'attach', '-nobrowse', '-readonly', '-mountpoint', mount, image)

  installed = File.join(mount, 'Bookalog Catalog.app')
  abort 'Disk image is missing the app executable.' unless File.executable?(File.join(installed, 'Contents/MacOS/Bookalog Catalog'))
  applications = File.join(mount, 'Applications')
  unless File.symlink?(applications) && File.readlink(applications) == '/Applications'
    abort 'Disk image is missing its drag-to-Applications link.'
  end
  plist = File.join(installed, 'Contents/Info.plist')
  {
    'CFBundleDisplayName' => 'Bookalog Catalog',
    'CFBundleURLTypes:0:CFBundleURLSchemes:0' => 'com.bookalog.catalog'
  }.each do |key, expected|
    value, status = Open3.capture2('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", plist)
    abort "Packaged macOS property #{key} does not match #{expected}." unless status.success? && value.strip == expected
  end
ensure
  # Never remove a staging tree while its read-only disk image is still mounted.
  run!('hdiutil', 'detach', mount) if File.stat(mount).dev != File.stat(stage).dev
  FileUtils.remove_entry_secure(stage)
end

puts "Verified unsigned disk image: #{image}"
