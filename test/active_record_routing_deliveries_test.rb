require "test_helper"
require "open3"
require "rbconfig"

class ActiveRecordRoutingDeliveriesIntegrationTest < Minitest::Test
  def test_routing_delivery_api_and_generated_migration
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/routing_deliveries.rb", __dir__))
    assert status.success?, output
  end

  def test_tenant_and_system_database_isolation
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/routing_tenants.rb", __dir__))
    assert status.success?, output
  end
end
