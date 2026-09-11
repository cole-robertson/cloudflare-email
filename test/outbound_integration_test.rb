require "test_helper"
require "open3"
require "rbconfig"

class OutboundIntegrationTest < Minitest::Test
  def test_mail_snapshot_jobs_and_event_projection
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/outbound_integration.rb", __dir__))
    assert status.success?, output
  end
end
