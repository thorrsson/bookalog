#!/usr/bin/env ruby
require 'base64'
require 'openssl'

abort 'Usage: ruby script/offline-lease-key.rb EXISTING_PRIVATE_DIRECTORY' unless ARGV.length == 1
directory = File.realpath(ARGV.fetch(0))
abort 'Select an existing private directory.' unless File.directory?(directory)
ancestor = directory
loop do
  abort 'Store signing secrets outside Git repositories.' if File.exist?(File.join(ancestor, '.git'))
  parent = File.dirname(ancestor)
  break if parent == ancestor

  ancestor = parent
end

private_path = File.join(directory, '.env.offline-lease')
public_path = File.join(directory, 'offline-public-key.txt')
abort 'Refusing to overwrite an existing signing key.' if File.exist?(private_path) || File.exist?(public_path)

key = OpenSSL::PKey.generate_key('ED25519')
public_key = Base64.urlsafe_encode64(key.public_to_der.byteslice(-32, 32), padding: false)
File.open(private_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.puts "OFFLINE_LEASE_PRIVATE_KEY=#{Base64.strict_encode64(key.private_to_der)}"
end
File.open(public_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.puts public_key
end
puts "Signing key saved to #{private_path}; keep it secret and outside Git."
puts "Public verification key saved to #{public_path}."
