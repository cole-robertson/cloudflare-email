require "test_helper"
require "open3"
require "rbconfig"

class MailboxIngressTest < Minitest::Test
  def test_real_rails_tenant_ingress_and_routing_jobs
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", File.expand_path("support/mailbox_ingress.rb", __dir__))
    assert status.success?, output
  end
end
