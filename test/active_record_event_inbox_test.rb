require "test_helper"
require "open3"
require "rbconfig"

class ActiveRecordEventInboxIntegrationTest < Minitest::Test
  def test_durable_receipts_and_generated_migration
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/event_inbox.rb", __dir__))
    assert status.success?, output
  end

  def test_plain_ruby_require_does_not_load_active_record
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e",
      'require "cloudflare-email"; abort "ActiveRecord loaded" if defined?(ActiveRecord::Base)')
    assert status.success?, output
  end
end
