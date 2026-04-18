require_relative "lib/cloudflare/email/version"

Gem::Specification.new do |spec|
  spec.name        = "cloudflare-email"
  spec.version     = Cloudflare::Email::VERSION
  spec.authors     = ["Cole"]
  spec.email       = ["cole@dscribeai.com"]
  spec.summary     = "Cloudflare Email Service client for Ruby and Rails (ActionMailer + ActionMailbox)."
  spec.description = "A Ruby client and Rails integration for Cloudflare's Email Service. " \
                     "Send mail via an ActionMailer delivery method, receive mail via an " \
                     "ActionMailbox ingress backed by a shipped Cloudflare Email Worker template."
  spec.homepage    = "https://github.com/cole-robertson/cloudflare-email"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  # Explicitly enumerate the files to ship so generated artifacts like
  # node_modules/ or .wrangler/ can never accidentally leak into the gem.
  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.rake",
    "app/**/*.rb",
    "templates/worker/README.md",
    "templates/worker/package.json",
    "templates/worker/wrangler.toml",
    "templates/worker/vitest.config.ts",
    "templates/worker/src/*.js",
    "templates/worker/test/*.test.ts",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt",
  ]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "webmock", "~> 3.20"
  spec.add_development_dependency "rails", ">= 7.1", "< 9.0"
  # sqlite3 version pin is deferred to Gemfile + gemfiles/rails_*.gemfile
  # variants because Rails 7.1 needs ~> 1.4 while 7.2+ needs >= 2.0.
  spec.add_development_dependency "rack-test", "~> 2.1"
end
