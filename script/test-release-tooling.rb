#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the release tooling stays consistent: the version Release Please
# manages, the workflows that sign and publish it, and the secrets script that
# provisions them. Nothing here signs, builds or talks to GitHub.

require 'json'
require 'minitest/autorun'
require 'open3'
require 'yaml'

ROOT = File.expand_path('..', __dir__)

def read(path) = File.read(File.join(ROOT, path))
def workflow(name) = YAML.safe_load(read(".github/workflows/#{name}"))

class ReleaseToolingTest < Minitest::Test
  def pubspec = YAML.safe_load(read('app/pubspec.yaml'))
  def app_version(*args)
    output, status = Open3.capture2e('ruby', File.join(ROOT, 'script/app-version.rb'), *args)
    assert status.success?, output
    output.chomp
  end

  def test_manifest_tracks_the_pubspec_version
    manifest = JSON.parse(read('.release-please-manifest.json'))
    assert_equal ['app'], manifest.keys
    assert_equal app_version, manifest['app']
  end

  def test_version_is_numeric_for_apple_and_msix
    assert_match(/\A\d+\.\d+\.\d+\z/, app_version)
    assert_match(/\A\d+\z/, app_version('build'))
    assert_equal "#{app_version}.0", app_version('msix')
  end

  def test_release_please_tags_desktop_drafts
    config = JSON.parse(read('.release-please-config.json'))
    assert_equal ['app'], config['packages'].keys
    app = config['packages']['app']
    assert_equal 'dart', app['release-type']
    assert_equal 'desktop', app['component']
    assert app['include-component-in-tag']
    assert app['draft']
    assert app['force-tag-creation'], 'draft releases need their tag for the tagged build'
  end

  def test_msix_signing_is_chosen_per_build
    msix = pubspec.fetch('msix_config')
    refute msix.key?('msix_version'), 'msix_version would pin the package version instead of the pubspec version'
    refute msix.key?('sign_msix'), 'sign_msix: false overrides --sign-msix true'
    assert_includes read('script/windows/release.sh'), '--sign-msix true'
    assert_includes read('script/build-desktop.sh'), '--sign-msix false'
  end

  def test_actions_are_pinned_and_checkouts_drop_credentials
    Dir[File.join(ROOT, '.github/workflows/*.yml')].each do |path|
      jobs = YAML.safe_load_file(path).fetch('jobs')
      jobs.each_value do |job|
        Array(job['steps']).each do |step|
          next unless (uses = step['uses'])

          assert_match(/@[0-9a-f]{40}\z/, uses, "#{File.basename(path)} must pin #{uses} to a commit")
          if uses.start_with?('actions/checkout@')
            assert_equal false, step.dig('with', 'persist-credentials'), "#{File.basename(path)} checkout keeps credentials"
          end
        end
      end
    end
  end

  def test_release_please_accepts_only_plain_versions
    run = workflow('release-please.yml').dig('jobs', 'release', 'steps').find { _1['id'] == 'release' }['run']
    pattern = run[/=~ \^(.*)\$ \]\]/, 1]
    regex = Regexp.new("\\A#{pattern}\\z")
    assert_match regex, '1.2.3'
    refute_match regex, '1.2.3-beta.1'
    assert_includes run, 'release-please--branches--$GITHUB_DEFAULT_BRANCH--components--desktop'
  end

  # A build called from the release-please run would deploy from the default
  # branch, which the release environment, limited to desktop-v* tags, refuses.
  def test_release_please_dispatches_the_build_on_its_tag
    release = workflow('release-please.yml')
    assert_equal ['release'], release['jobs'].keys
    assert_includes YAML.dump(release), 'gh workflow run desktop-release.yml --ref "$TAG"'
    assert_includes release['jobs']['release']['steps'].find { _1['id'] == 'auto_merge' }['run'], 'gh workflow run ci.yml'
    triggers = workflow('desktop-release.yml').fetch('on')
    assert_equal({ 'tags' => ['desktop-v*'] }, triggers['push'])
    assert triggers.key?('workflow_dispatch')
    refute triggers.key?('workflow_call')
    assert workflow('ci.yml').fetch('on').key?('workflow_dispatch')
  end

  def test_only_signing_jobs_see_the_release_environment
    jobs = workflow('desktop-release.yml').fetch('jobs')
    environments = jobs.to_h { |name, job| [name, job['environment']] }
    assert_equal({ 'version' => nil, 'macos' => 'release', 'windows' => 'release', 'release' => nil }, environments)
    macos = jobs['macos']['steps'].find { _1['name'] == 'Build, sign, notarize' }['env']
    %w[BOOKALOG_REQUIRE_NOTARIZATION BOOKALOG_REQUIRE_CONFIGURATION].each { assert_equal '1', macos[_1] }
    assert_equal '1', jobs['windows']['steps'].find { _1['name'] == 'Build and sign' }.dig('env', 'BOOKALOG_REQUIRE_CONFIGURATION')
  end

  def test_secrets_script_provisions_what_the_workflow_reads
    text = read('.github/workflows/desktop-release.yml')
    script = read('script/macos/push-release-secrets.sh')
    secrets = text.scan(/secrets\.([A-Z0-9_]+)/).flatten.uniq
    variables = text.scan(/vars\.([A-Z0-9_]+)/).flatten.uniq
    refute_empty secrets
    secrets.each { assert_match(/set_secret #{_1} /, script, "push-release-secrets.sh does not set #{_1}") }
    variables.each { assert_match(/set_variable #{_1} /, script, "push-release-secrets.sh does not set #{_1}") }
    assert_includes script, 'TAG_PATTERN="desktop-v*"'
  end

  def test_release_scripts_parse
    scripts = Dir[File.join(ROOT, 'script/{macos,windows}/*.sh')] + [File.join(ROOT, 'script/release-common.sh')]
    assert_operator scripts.size, :>=, 7
    scripts.each do |path|
      output, status = Open3.capture2e('bash', '-n', path)
      assert status.success?, "#{path}: #{output}"
    end
  end
end
