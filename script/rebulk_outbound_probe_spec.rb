# frozen_string_literal: true
#
# Optional Rebulk migration CHARACTERIZATION probe, excluded from default CI.
# Passing checks reproduce known migration gaps (including false sent states),
# NOT acceptance criteria or evidence that Rebulk is ready to change providers.
# Reviewed with Rebulk commit 46db134 and cloudflare-email commit 9d1cd58.
#
# Use an isolated Rebulk checkout with dependencies installed. Reserve test
# worker 9 exclusively for this run; its primary/tenant databases are local test
# fixtures and db:test:prepare may recreate them. No real email is sent.
#
# From the cloudflare-email checkout:
#   export CLOUDFLARE_PROBE="$(pwd)/script/rebulk_outbound_probe_spec.rb"
#   export REBULK_REPO=/absolute/path/to/isolated/rebulk
#   cd "$REBULK_REPO"
#   env -u DATABASE_URL -u RAILS_MASTER_KEY RAILS_ENV=test TEST_ENV_NUMBER=9 \
#     NIGHTRAIL_TOKEN= LANTERN_TOKEN= bundle exec rails db:test:prepare
#   env -u DATABASE_URL -u RAILS_MASTER_KEY RAILS_ENV=test TEST_ENV_NUMBER=9 \
#     NIGHTRAIL_TOKEN= LANTERN_TOKEN= bundle exec rspec "$CLOUDFLARE_PROBE"
#
# Another explicitly reserved positive TEST_ENV_NUMBER is supported. Run this
# file alone, using Rebulk's bundle. It loads the gem's source from this script's
# checkout and registers the adapter only in this test process; no application
# dependency, initializer, or deployed configuration is changed.

abort "Set RAILS_ENV=test before running this probe" unless ENV["RAILS_ENV"] == "test"
unless ENV["TEST_ENV_NUMBER"].to_s.match?(/\A[1-9]\d*\z/)
  abort "Reserve a unique TEST_ENV_NUMBER (for example 9) before running this probe"
end

rebulk_repo = File.realpath(ENV.fetch("REBULK_REPO"))
abort "REBULK_REPO must contain the Rebulk Rails checkout" unless File.file?(File.join(rebulk_repo, "spec/rails_helper.rb"))
require "bundler"
unless File.realpath(Bundler.default_gemfile) == File.join(rebulk_repo, "Gemfile")
  abort "Run bundle exec rspec from REBULK_REPO using its Gemfile"
end

# Remove inherited runtime connection/telemetry credentials before Rails boots.
ENV.delete("DATABASE_URL")
ENV.delete("RAILS_MASTER_KEY")
ENV["NIGHTRAIL_TOKEN"] = ""
ENV["LANTERN_TOKEN"] = ""
ENV["SMTP_ADDRESS"] = "email-smtp.us-east-1.amazonaws.com"

require "webmock/rspec"
WebMock.disable_net_connect!
Dir.chdir(rebulk_repo)
$LOAD_PATH.unshift File.join(rebulk_repo, "spec")
require "rails_helper"
# Rebulk's rails_helper permits loopback; this probe needs no real connections.
WebMock.disable_net_connect!
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cloudflare-email"
require "cloudflare/email/delivery_method"

RSpec.describe "Cloudflare/Rebulk migration characterization (NOT acceptance)", :tenant, type: :mailer do
  let!(:org) { create(:organization, name: "Dogfood Yard", slug: "test-tenant") }
  let!(:user) { create(:user, email: "dogfood@example.test") }
  let(:endpoint) { "https://api.cloudflare.com/client/v4/accounts/dogfood-account/email/sending/send_raw" }

  around do |example|
    original_method = ApplicationMailer.delivery_method
    ActionMailer::Base.add_delivery_method :cloudflare, Cloudflare::Email::DeliveryMethod
    ApplicationMailer.delivery_method = :cloudflare
    ApplicationMailer.cloudflare_settings = { account_id: "dogfood-account", api_token: "fake-test-token", retries: 0 }
    WebMock.disable_net_connect!
    Current.set(organization: org) { example.run }
  ensure
    ApplicationMailer.delivery_method = original_method
  end

  def provider_response(outcome: "delivered", recipient: user.email)
    { "success" => true, "result" => { "message_id" => "provider-id@cloudflare.example",
      "delivered" => [], "queued" => [], "permanent_bounces" => [], "suppressed_recipients" => [],
      outcome => [recipient] } }
  end

  def report_mail
    create(:organization_membership, user: user, organization: org, role: "editor")
    @attempt = create(:report_email, report_key: "current_inventory_and_transloads",
      sent_by_user_id: user.id, recipient_email: "report@example.test", formats: "csv", status: "queued")
    ReportMailer.with(org_slug: org.slug, report_key: @attempt.report_key,
      report_email_id: @attempt.id, recipient_email: @attempt.recipient_email,
      sent_by_user_id: user.id, formats: ["csv"]).manual_send
  end

  it "renders and sends the actual UserMailer while exposing stale recorded provider identity" do
    request = stub_request(:post, endpoint).with do |req|
      body = JSON.parse(req.body)
      body["recipients"] == [user.email] && body["mime_message"].include?("Verify your email")
    end.to_return(status: 200, body: JSON.generate(provider_response))
    message = UserMailer.with(user: user).email_verification.deliver_now
    expect(request).to have_been_requested.once
    expect(message.message_id).to eq("provider-id@cloudflare.example")
    row = CommunicationMessage.find_by!(dedup_key: message[CommunicationsEmailTracker::HEADER].value)
    expect(row.status).to eq("accepted")
    expect(row.provider).to eq("ses")
    expect(row.provider_message_id).not_to eq(message.message_id)
  end

  it "sends an actual report attachment and marks its audit sent" do
    delivery = report_mail
    request = stub_request(:post, endpoint).with do |req|
      payload = JSON.parse(req.body)
      payload["recipients"] == ["report@example.test"] && payload["mime_message"].include?("text/csv")
    end.to_return(status: 200, body: JSON.generate(provider_response(recipient: "report@example.test")))
    delivery.deliver_now
    expect(request).to have_been_requested.once
    expect(@attempt.reload.status).to eq("sent")
  end

  ["permanent_bounces", "suppressed_recipients"].each do |outcome|
    it "demonstrates that #{outcome} still marks a report sent with current app observers" do
      delivery = report_mail
      request = stub_request(:post, endpoint).to_return(status: 200,
        body: JSON.generate(provider_response(outcome: outcome, recipient: "report@example.test")))
      delivery.deliver_now
      expect(request).to have_been_requested.once
      expect(@attempt.reload.status).to eq("sent")
      expect(CommunicationMessage.where(channel: "email", direction: "outbound").recent.first.status).to eq("accepted")
    end
  end

  it "demonstrates that the report claim fails to classify wrapped read timeout as ambiguous" do
    delivery = report_mail
    request = stub_request(:post, endpoint).to_raise(Net::ReadTimeout)
    expect { delivery.deliver_now }.to raise_error(Cloudflare::Email::NetworkError, /outcome is unknown/)
    expect(request).to have_been_requested.once
    expect(@attempt.reload.status).to eq("queued")
    expect(@attempt.skip_reason).to be_nil
  end

  it "demonstrates that SMTP job retry handlers do not retry a Cloudflare rate limit" do
    request = stub_request(:post, endpoint).to_return(status: 429,
      body: JSON.generate("success" => false, "errors" => [{ "message" => "synthetic rate limit" }]))
    clear_enqueued_jobs
    expect do
      ActionMailer::MailDeliveryJob.perform_now("UserMailer", "email_verification", "deliver_now",
        params: { user: user }, args: [])
    end.to raise_error(Cloudflare::Email::RateLimitError)
    expect(request).to have_been_requested.once
    expect(enqueued_jobs).to be_empty
  end
end
