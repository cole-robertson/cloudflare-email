require "test_helper"
require "open3"
require "rbconfig"

class RailsIntegrationTest < Minitest::Test
  %w[inbound send_only].each do |mode|
    define_method("test_#{mode}_application") do
      output, status = Open3.capture2e(
        RbConfig.ruby, File.expand_path("support/rails_app.rb", __dir__), mode,
      )
      assert status.success?, output
    end
  end
end
