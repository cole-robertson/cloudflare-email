require "test_helper"
require "open3"
require "rbconfig"

class MailboxModelsTest < Minitest::Test
  def test_fresh_mailbox_generator_installation
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/mailbox_generator.rb", __dir__))
    assert status.success?, output
  end

  def test_optional_mailbox_models
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/mailbox_models.rb", __dir__))
    assert status.success?, output
  end
end
