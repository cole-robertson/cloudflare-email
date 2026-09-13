require_relative "lib/mailbox_kit/version"
Gem::Specification.new do |spec|
  spec.name = "mailbox-kit"
  spec.version = MailboxKit::VERSION
  spec.authors = ["Cole"]
  spec.email = ["cole@dscribeai.com"]
  spec.summary = "Provider-neutral mailbox storage, routing and management for Rails."
  spec.homepage = "https://github.com/cole-robertson/cloudflare-email"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*", "app/**/*", "README.md", "LICENSE.txt"].select { |path| File.file?(path) }
  spec.require_paths = ["lib"]
end
