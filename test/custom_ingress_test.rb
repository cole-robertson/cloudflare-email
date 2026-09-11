require "test_helper"
require "open3"
require "rbconfig"

class CustomIngressTest < Minitest::Test
  def test_host_owned_ingress_with_separate_sqlite_tenants
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", File.expand_path("support/custom_ingress.rb", __dir__))
    assert status.success?, output
  end
end

