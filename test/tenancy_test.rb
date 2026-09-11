require "test_helper"
require "open3"
require "rbconfig"

class TenancyTest < Minitest::Test
  def test_optional_single_database_job_context
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/default_tenant_jobs.rb", __dir__))
    assert status.success?, output
  end

  def test_real_sqlite_tenant_connections
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/tenancy.rb", __dir__))
    assert status.success?, output
  end
end
