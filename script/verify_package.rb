# frozen_string_literal: true

# Build the distributable, load it through an isolated consumer bundle, then
# boot the real Rails fixtures against extracted packaged files, not source.
# Run: bundle exec ruby script/verify_package.rb
require "bundler"
require "fileutils"
require "tmpdir"
require "rbconfig"
require "rubygems/package"
require "cloudflare-email"

root = File.expand_path("..", __dir__)
version = Cloudflare::Email::VERSION
bundle_executable = Gem.bin_path("bundler", "bundle")
base64_cache = Gem.loaded_specs.fetch("base64").cache_file
abort "Missing Base64 gem cache; run bundle install before package verification" unless File.file?(base64_cache)

def run!(*args, **options)
  return if system(*args, **options)
  abort "Package verification command failed"
end

Dir.mktmpdir("cloudflare-email-package-") do |temporary|
  archive = File.join(temporary, "cloudflare-email-#{version}.gem")
  run!(RbConfig.ruby, "-S", "gem", "build", "cloudflare-email.gemspec", "--output", archive, chdir: root)
  extracted = File.join(temporary, "extracted")
  Gem::Package.new(archive).extract_files(extracted)

  consumer = File.join(temporary, "consumer")
  cache = File.join(consumer, "vendor/cache")
  FileUtils.mkdir_p(cache)
  FileUtils.cp(archive, cache)
  FileUtils.cp(base64_cache, cache)
  File.write(File.join(consumer, "Gemfile"), <<~GEMFILE)
    source "https://rubygems.org"
    gem "cloudflare-email", "#{version}"
  GEMFILE
  check = <<~RUBY
    require "cloudflare-email"
    abort "unexpected Rails dependency" if defined?(Rails) || Gem.loaded_specs.key?("rails")
    abort "wrong gem version" unless Cloudflare::Email::VERSION == #{version.inspect}
    abort "missing event consumer" unless defined?(Cloudflare::Email::EventConsumer)
    abort "gem was not installed from the package" unless Gem.loaded_specs.fetch("cloudflare-email").full_gem_path.start_with?(#{File.join(temporary, "installed").inspect})
    puts "PASS: isolated packaged Ruby consumer (no Rails)"
  RUBY
  Bundler.with_unbundled_env do
    environment = {
      "BUNDLE_GEMFILE" => File.join(consumer, "Gemfile"),
      "BUNDLE_PATH" => File.join(temporary, "installed"),
      "BUNDLE_FROZEN" => "false", "BUNDLE_DEPLOYMENT" => "false",
    }
    run!(environment, RbConfig.ruby, bundle_executable, "install", "--local", "--quiet", chdir: consumer)
    run!(environment, RbConfig.ruby, bundle_executable, "exec", RbConfig.ruby, "-e", check, chdir: consumer)
  end

  %w[inbound send_only fresh_inbound].each do |mode|
    run!({ "CLOUDFLARE_EMAIL_TEST_GEM_ROOT" => extracted }, RbConfig.ruby,
         File.join(root, "test/support/rails_app.rb"), mode, chdir: root)
  end
  puts "PASS: packaged Rails installation and ingress fixtures"
  run!({ "CLOUDFLARE_EMAIL_TEST_GEM_ROOT" => extracted }, RbConfig.ruby,
       File.join(root, "test/support/outbound_integration.rb"), chdir: root)
  puts "PASS: packaged outbound snapshots, jobs, and delivery-event projection"
end
