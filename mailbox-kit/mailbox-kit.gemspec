require_relative "lib/mailbox_kit/version"
Gem::Specification.new do |spec|
  spec.name = "mailbox-kit"
  spec.version = MailboxKit::VERSION
  spec.authors = ["Cole"]
  spec.email = ["cole@dscribeai.com"]
  spec.summary = "Persistent inboxes and management UI built on Rails Action Mailbox."
  spec.description = "Provider-neutral mailbox identities, aliases, memberships, retention, optional tenancy, and a server-rendered management engine built on Rails Action Mailbox."
  spec.homepage = "https://github.com/cole-robertson/cloudflare-email"
  spec.license = "MIT"
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/mailbox-kit"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*", "app/**/*", "docs/**/*.md", "README.md", "LICENSE.txt"].select { |path| File.file?(path) }
  spec.require_paths = ["lib"]
end
