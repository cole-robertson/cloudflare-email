require "test_helper"
require "open3"
require "rbconfig"

class MailboxServiceTest < Minitest::Test
  def test_real_sqlite_tenant_mailbox_services
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/mailbox_service.rb", __dir__))
    assert status.success?, output
  end
end
