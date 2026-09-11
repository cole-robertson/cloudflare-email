require "test_helper"
require "open3"
require "rbconfig"

class MailboxEventsSubprocessTest < Minitest::Test
  def test_shared_intake_and_two_sqlite_tenant_projection
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/mailbox_events.rb", __dir__))
    assert status.success?, output
  end
end
