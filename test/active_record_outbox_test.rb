require "test_helper"
require "open3"
require "rbconfig"

class ActiveRecordOutboxIntegrationTest < Minitest::Test
  def test_outbox_and_generated_migration
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/outbox.rb", __dir__))
    assert status.success?, output
  end
end
