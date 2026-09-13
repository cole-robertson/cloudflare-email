require "test_helper"
require "open3"
require "rbconfig"

class MailboxCoreTest < Minitest::Test
  def test_standalone_tenant_database_jobs
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/mailbox_core_tenancy.rb", __dir__))
    assert status.success?, output
  end

  def test_management_and_persistence_without_cloudflare
    output, status = Open3.capture2e({ "MAILBOX_KIT_ONLY" => "1" }, RbConfig.ruby,
      File.expand_path("support/management_engine.rb", __dir__))
    assert status.success?, output
  end

  def test_standalone_routing_without_cloudflare
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/mailbox_core.rb", __dir__))
    assert status.success?, output
  end

  def test_mixed_core_and_cloudflare_schema
    output, status = Open3.capture2e({ "MAILBOX_KIT_MIXED" => "1" }, RbConfig.ruby,
      File.expand_path("support/mailbox_core.rb", __dir__))
    assert status.success?, output
  end
end
