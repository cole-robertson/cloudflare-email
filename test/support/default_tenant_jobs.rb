require_relative "../test_helper"
require "active_job"
require "cloudflare/email/tenant_job_context"

ActiveJob::Base.logger = Logger.new(File::NULL)

module ActionMailbox
  class RoutingJob < ActiveJob::Base
    def perform
      Cloudflare::Email::Tenancy.current_key
    end
  end
end
Cloudflare::Email::TenantJobContext.install_framework_jobs!

class DefaultTenantJobsTest < Minitest::Test
  Tenancy = Cloudflare::Email::Tenancy
  PayloadKey = Cloudflare::Email::TenantJobContext::PAYLOAD_KEY

  def test_preserves_unconfigured_framework_job_behavior
    payload = ActionMailbox::RoutingJob.new.serialize
    refute payload.key?(PayloadKey)
    assert_nil ActiveJob::Base.execute(payload)
  end

  def test_single_database_mailbox_context_is_preserved
    payload = Tenancy.with("alpha") { ActionMailbox::RoutingJob.new.serialize }
    assert_equal "alpha", payload.fetch(PayloadKey)
    Tenancy.with("beta") do
      assert_equal "alpha", ActiveJob::Base.execute(payload)
      assert_equal "beta", Tenancy.current_key
    end
    assert_nil Tenancy.current_key
  end

  def test_legacy_payload_is_not_rewritten_with_ambient_tenant_on_retry
    payload = ActionMailbox::RoutingJob.new.serialize
    Tenancy.with("beta") do
      job = ActiveJob::Base.deserialize(payload)
      refute job.serialize.key?(PayloadKey)
    end
  end
end
