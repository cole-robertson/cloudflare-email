require "test_helper"
require "open3"
require "rbconfig"

class RailsIntegrationTest < Minitest::Test
  def test_development_tunnel_guard_boot
    output, status = Open3.capture2e(RbConfig.ruby, File.expand_path("support/development_guard.rb", __dir__))
    assert status.success?, output
  end

  %w[inbound send_only fresh_inbound].each do |mode|
    define_method("test_#{mode}_application") do
      output, status = Open3.capture2e(
        RbConfig.ruby, File.expand_path("support/rails_app.rb", __dir__), mode,
      )
      assert status.success?, output
    end
  end
end
