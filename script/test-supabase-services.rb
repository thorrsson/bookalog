#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'securerandom'
require 'socket'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
CLI = File.join(ROOT, 'node_modules', '.bin', 'supabase')
abort 'Run npm ci with an isolated cache before the service wrapper.' unless File.executable?(CLI)

def command(*args, env: {})
  output, error, status = Open3.capture3(env, *args)
  unless status.success?
    diagnostic = "#{error}\n#{output}".lines.last(25).join
      .gsub(%r{postgres(?:ql)?://\S+}, '[database URL redacted]')
      .gsub(/\beyJ[A-Za-z0-9_.-]+/, '[token redacted]')
      .gsub(/\bsb_(?:secret|publishable)_[A-Za-z0-9_-]+/, '[key redacted]')
    raise "#{File.basename(args.first)} failed (#{status.exitstatus}):\n#{diagnostic}"
  end
  output
end

def free_ports(count)
  sockets = Array.new(count) { TCPServer.new('127.0.0.1', 0) }
  sockets.map { |socket| socket.addr[1] }
ensure
  sockets&.each(&:close)
end

def local_certificate(directory)
  authority_key = OpenSSL::PKey::RSA.new(2048)
  authority = OpenSSL::X509::Certificate.new
  authority.version = 2
  authority.serial = SecureRandom.random_number(2**128)
  authority.subject = OpenSSL::X509::Name.parse('/CN=Bookalog disposable test authority')
  authority.issuer = authority.subject
  authority.public_key = authority_key.public_key
  authority.not_before = Time.now - 60
  authority.not_after = Time.now + 3600
  factory = OpenSSL::X509::ExtensionFactory.new
  factory.subject_certificate = authority
  factory.issuer_certificate = authority
  authority.add_extension(factory.create_extension('basicConstraints', 'CA:TRUE,pathlen:0', true))
  authority.add_extension(factory.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
  authority.add_extension(factory.create_extension('subjectKeyIdentifier', 'hash'))
  authority.sign(authority_key, OpenSSL::Digest.new('SHA256'))

  key = OpenSSL::PKey::RSA.new(2048)
  certificate = OpenSSL::X509::Certificate.new
  certificate.version = 2
  certificate.serial = SecureRandom.random_number(2**128)
  certificate.subject = OpenSSL::X509::Name.parse('/CN=localhost')
  certificate.issuer = authority.subject
  certificate.public_key = key.public_key
  certificate.not_before = Time.now - 60
  certificate.not_after = Time.now + 3600
  factory.subject_certificate = certificate
  factory.issuer_certificate = authority
  certificate.add_extension(factory.create_extension('basicConstraints', 'CA:FALSE', true))
  certificate.add_extension(factory.create_extension('keyUsage', 'digitalSignature,keyEncipherment', true))
  certificate.add_extension(factory.create_extension('extendedKeyUsage', 'serverAuth'))
  certificate.add_extension(factory.create_extension('subjectAltName', 'DNS:localhost,IP:127.0.0.1'))
  certificate.add_extension(factory.create_extension('authorityKeyIdentifier', 'keyid:always'))
  certificate.sign(authority_key, OpenSSL::Digest.new('SHA256'))
  File.write(File.join(directory, 'ca.pem'), authority.to_pem, mode: 'wx', perm: 0o600)
  File.write(File.join(directory, 'cert.pem'), certificate.to_pem + authority.to_pem, mode: 'wx', perm: 0o600)
  File.write(File.join(directory, 'key.pem'), key.to_pem, mode: 'wx', perm: 0o600)
end

abort 'Restore the pinned Supabase CLI 3.0.0 with npm ci.' unless command(CLI, '--version').strip == '3.0.0'
command(ENV.fetch('FLUTTER_BIN', 'flutter'), '--version')
command('docker', 'info', '--format', '{{.ServerVersion}}')
FileUtils.mkdir_p(File.join(ROOT, '.cache'))
directory = Dir.mktmpdir('bookalog-services-', File.join(ROOT, '.cache'))
project = "bookalog-test-#{SecureRandom.hex(6)}"
network = "#{project}-network"
network_created = false
started = false
failure = nil
environment = { 'SUPABASE_ACCESS_TOKEN' => nil, 'SUPABASE_DB_PASSWORD' => nil }

begin
  api_port, database_port, shadow_port = free_ports(3)
  FileUtils.mkdir_p(File.join(directory, 'supabase', 'migrations'))
  Dir.glob(File.join(ROOT, 'supabase', 'migrations', '*.sql')).each do |migration|
    FileUtils.cp(migration, File.join(directory, 'supabase', 'migrations'))
  end
  local_certificate(directory)
  File.write(File.join(directory, 'supabase', 'config.toml'), <<~TOML)
    project_id = "#{project}"
    [api]
    enabled = true
    port = #{api_port}
    schemas = ["public"]
    max_rows = 1000
    [api.tls]
    enabled = true
    cert_path = "../cert.pem"
    key_path = "../key.pem"
    [db]
    port = #{database_port}
    shadow_port = #{shadow_port}
    major_version = 17
    [db.seed]
    enabled = false
    [db.pooler]
    enabled = false
    [auth]
    enabled = true
    site_url = "https://127.0.0.1:#{api_port}"
    enable_signup = true
    [auth.email]
    enable_signup = true
    enable_confirmations = false
    [studio]
    enabled = false
    [local_smtp]
    enabled = false
    [realtime]
    enabled = false
    [analytics]
    enabled = false
    [edge_runtime]
    enabled = false
    [storage]
    enabled = true
    file_size_limit = "10MiB"
    [storage.vector]
    enabled = false
  TOML
  command('docker', 'network', 'create', '--driver', 'bridge', '--opt',
    'com.docker.network.bridge.host_binding_ipv4=127.0.0.1', network)
  network_created = true
  puts "Starting isolated project #{project} (first run downloads service images)."
  started = true
  command(CLI, 'start', '--workdir', directory, '--network-id', network, '--exclude',
    'realtime,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor',
    env: environment)
  containers = command('docker', 'ps', '-q', '--filter', "network=#{network}").split
  raise 'The local stack started no containers.' if containers.empty?
  containers.each do |id|
    inspection = JSON.parse(command('docker', 'inspect', id)).fetch(0)
    raise 'Unexpected container on the isolated network.' unless inspection.fetch('Name').include?(project)
    inspection.fetch('NetworkSettings').fetch('Ports', {}).each_value do |bindings|
      next unless bindings
      raise 'A local service is not restricted to loopback.' unless bindings.all? { |binding| binding['HostIp'] == '127.0.0.1' }
    end
  end
  status = command(CLI, 'status', '--workdir', directory, '-o', 'json', env: environment)
  File.write(File.join(directory, 'status.json'), status, mode: 'wx', perm: 0o600)
  puts 'Running real-provider checks over locally trusted HTTPS; credentials stay in the disposable directory.'
  test_environment = environment.merge(
    'NODE_EXTRA_CA_CERTS' => File.join(directory, 'ca.pem'),
    'BOOKALOG_SERVICE_TEST_DIRECTORY' => directory,
    'BOOKALOG_SERVICE_TEST_PROJECT' => project
  )
  success = system(test_environment, 'node', File.join(ROOT, 'supabase', 'tests', 'services.mjs'))
  raise 'Local provider or recovery checks failed.' unless success
  puts 'Running the actual Flutter repository adapter against the same disposable services.'
  success = system(test_environment, 'bash', File.join(ROOT, 'script', 'test-app.sh'),
    'test/provider_integration_test.dart')
  raise 'Flutter provider integration checks failed.' unless success
rescue StandardError => error
  failure = error
ensure
  if started
    begin
      command(CLI, 'stop', '--workdir', directory, '--project-id', project, '--no-backup', env: environment)
    rescue StandardError => error
      warn "Could not clean up isolated project #{project}: #{error.message}"
      failure ||= error
    end
  end
  if network_created
    begin
      command('docker', 'network', 'rm', network)
    rescue StandardError => error
      warn "Could not remove test network #{network}: #{error.message}"
      failure ||= error
    end
  end
  begin
    remaining_containers = command('docker', 'ps', '-aq', '--filter', "name=_#{project}$").strip
    remaining_volumes = command('docker', 'volume', 'ls', '-q', '--filter', "name=_#{project}$").strip
    raise "Resources remain for isolated project #{project}." unless remaining_containers.empty? && remaining_volumes.empty?
  rescue StandardError => error
    warn "Cleanup verification failed: #{error.message}"
    failure ||= error
  end
  # This is the exact private temporary child created above, never the workspace/cache root.
  FileUtils.remove_entry_secure(directory)
end

abort failure.message if failure
puts 'Local provider and recovery checks passed; isolated containers, volumes and credentials removed.'
