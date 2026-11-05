#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

source = File.expand_path('validate-onix.sh', __dir__)
expected = '99d68d13d964de6e2827c5b330ca2a9d20b3fc185db587b24fc1e0441242e774'
scenarios = {
  'trusted' => [0, 1, true, true],
  'mismatch-then-trusted' => [0, 2, true, true],
  'error-then-trusted' => [0, 2, true, true],
  'mismatch' => [1, 3, false, false],
  'transport-error' => [1, 3, false, false],
  'cached-trusted' => [0, 0, true, true],
  'cached-mismatch' => [1, 0, true, false],
  'invalid-xml' => [3, 1, true, true]
}

scenarios.each do |scenario, (exit_code, requests, cached, extracted)|
  Dir.mktmpdir('bookalog-onix-validator-') do |root|
    scripts = File.join(root, 'script')
    bin = File.join(root, 'bin')
    cache = File.join(root, '.cache', 'onix')
    FileUtils.mkdir_p([scripts, bin, cache])
    FileUtils.cp(source, scripts)
    xml = File.join(root, 'sample.xml')
    File.write(xml, '<synthetic/>')
    File.write(File.join(root, 'requests'), '0')
    if scenario.start_with?('cached-')
      File.write(File.join(cache, 'schema.zip'), scenario == 'cached-trusted' ? 'trusted' : 'mismatch')
    end
    mocks = {
      'curl' => <<~'SH',
        #!/usr/bin/env bash
        set -euo pipefail
        count="$(cat "$MOCK_ROOT/requests")"
        count="$((count + 1))"
        printf '%s' "$count" > "$MOCK_ROOT/requests"
        printf '%s\n' "$@" > "$MOCK_ROOT/request-$count"
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then output="$2"; shift; fi
          shift
        done
        if [ "$MOCK_SCENARIO" = transport-error ] ||
          { [ "$MOCK_SCENARIO" = error-then-trusted ] && [ "$count" -eq 1 ]; }; then
          exit 22
        fi
        if [ "$MOCK_SCENARIO" = mismatch ] ||
          { [ "$MOCK_SCENARIO" = mismatch-then-trusted ] && [ "$count" -eq 1 ]; }; then
          printf 'mismatch' > "$output"
        else
          printf 'trusted' > "$output"
        fi
      SH
      'openssl' => <<~'SH',
        #!/usr/bin/env bash
        set -euo pipefail
        if [ "$(cat "$3")" = trusted ]; then
          printf 'SHA256(file)= %s\n' "$MOCK_EXPECTED"
        else
          printf 'SHA256(file)= untrusted\n'
        fi
      SH
      'unzip' => <<~'SH',
        #!/usr/bin/env bash
        set -euo pipefail
        test "$(cat "$MOCK_ROOT/.cache/onix/schema.zip")" = trusted
        touch "$MOCK_ROOT/extracted"
      SH
      'xmllint' => <<~'SH',
        #!/usr/bin/env bash
        set -euo pipefail
        test -f "$MOCK_ROOT/extracted"
        touch "$MOCK_ROOT/validated"
        if [ "$MOCK_SCENARIO" = invalid-xml ]; then exit 3; fi
      SH
      'sleep' => "#!/usr/bin/env bash\nexit 0\n"
    }
    mocks.each do |name, contents|
      file = File.join(bin, name)
      File.write(file, contents)
      File.chmod(0o700, file)
    end
    output, error, status = Open3.capture3(
      { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'MOCK_ROOT' => root,
        'MOCK_SCENARIO' => scenario, 'MOCK_EXPECTED' => expected },
      'bash', File.join(scripts, 'validate-onix.sh'), xml
    )
    raise "#{scenario}: expected exit #{exit_code}, got #{status.exitstatus}\n#{output}\n#{error}" unless status.exitstatus == exit_code
    raise "#{scenario}: incorrect request count" unless File.read(File.join(root, 'requests')).to_i == requests
    (1..requests).each do |request|
      arguments = File.readlines(File.join(root, "request-#{request}"), chomp: true)
      { '--connect-timeout' => '10', '--max-time' => '60', '--max-filesize' => '10485760',
        '--proto' => '=https', '--proto-redir' => '=https' }.each do |option, value|
        index = arguments.index(option)
        raise "#{scenario}: missing download constraint #{option} #{value}" unless index && arguments[index + 1] == value
      end
    end
    raise "#{scenario}: incorrect cache state" unless File.exist?(File.join(cache, 'schema.zip')) == cached
    raise "#{scenario}: unverified archive was extracted or verified archive was skipped" unless File.exist?(File.join(root, 'extracted')) == extracted
    raise "#{scenario}: validation step was skipped or incorrectly attempted" unless File.exist?(File.join(root, 'validated')) == extracted
    raise "#{scenario}: partial download was not removed" unless Dir.glob(File.join(cache, '*.part.*')).empty?
  end
end

puts 'ONIX validator controls passed: bounded retries, unchanged checksum pin, cache rejection and cleanup.'
