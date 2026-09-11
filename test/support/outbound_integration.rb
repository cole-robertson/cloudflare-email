require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "mail"
require "cloudflare/email/active_record"
require "cloudflare/email/send_job"
require "cloudflare/email/replay_events_job"
require "generators/cloudflare/email/outbox/templates/create_cloudflare_email_outbox"
require "generators/cloudflare/email/tracking/templates/create_cloudflare_email_event_receipts"

INTEGRATION_ROOT = Dir.mktmpdir("cloudflare-email-integration")
Minitest.after_run { FileUtils.remove_entry(INTEGRATION_ROOT) }
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(INTEGRATION_ROOT, "test.sqlite3"))
ActiveRecord::Migration.verbose = false
CreateCloudflareEmailOutbox.new.migrate(:up)
CreateCloudflareEmailEventReceipts.new.migrate(:up)
ActiveRecord::Schema.define do
  create_table(:outbox_projections) { |t| t.string :status }
end
class OutboxProjection < ActiveRecord::Base; end

class OutboundIntegrationChecks < Minitest::Test
  Outbox = Cloudflare::Email::ActiveRecord::Outbox
  Delivery = Cloudflare::Email::ActiveRecord::OutboundDelivery
  Recipient = Cloudflare::Email::ActiveRecord::OutboundRecipient
  Receipt = Cloudflare::Email::ActiveRecord::EventReceipt
  Events = Cloudflare::Email::ActiveRecord::DeliveryEvents
  Reconciliation = Cloudflare::Email::ActiveRecord::OutboundReconciliation
  Job = Cloudflare::Email::SendJob

  def setup
    Receipt.delete_all
    Reconciliation.delete_all
    Recipient.delete_all
    Delivery.delete_all
    OutboxProjection.delete_all
    Job.logger = Logger.new(nil)
  end

  def prepare(key: "operation", recipients: ["Recipient@example.net"])
    Outbox.prepare(account_id: ACCOUNT_ID, operation_key: key, from: "sender@example.com",
      recipients: recipients, mime_message: "From: sender@example.com\r\n\r\nimmutable")
  end

  def event(id: "event-123", status: "delivered", account: ACCOUNT_ID, recipient: "Recipient@EXAMPLE.NET", time: "2026-09-10T00:00:00Z")
    Cloudflare::Email::DeliveryEvent.new({
      "type" => "cf.email.sending.message.#{status}",
      "source" => { "type" => "email.sending", "domain" => "example.com" },
      "metadata" => { "accountId" => account, "eventSchemaVersion" => 1, "eventTimestamp" => time },
      "payload" => { "eventId" => id, "messageId" => "<provider@example.com>",
        "recipient" => recipient, "terminal" => status != "deferred" },
    })
  end

  def accept(delivery)
    stub_request(:post, send_raw_endpoint).to_return(body: JSON.generate(success: true,
      result: { message_id: "provider@example.com" }))
    Outbox.deliver(delivery, client: make_client)
  end

  def test_snapshot_preserves_attachment_and_bcc_envelope_and_refuses_disabled_mail
    mail = Mail.new do
      from "sender@example.com"
      to "visible@example.net"
      bcc "hidden@example.net"
      subject "snapshot"
      body "unchanged"
    end
    mail.attachments["binary.bin"] = (0..255).to_a.pack("C*")
    original = mail.encoded
    delivery = Outbox.prepare_mail(account_id: ACCOUNT_ID, operation_key: "mail", mail: mail)
    assert_equal original.b, delivery.mime_message
    assert_equal ["visible@example.net", "hidden@example.net"], delivery.recipients
    assert_equal (0..255).to_a.pack("C*"), Mail.read_from_string(delivery.mime_message).attachments.first.decoded
    mail.perform_deliveries = false
    assert_raises(Cloudflare::Email::ValidationError) { Outbox.prepare_mail(account_id: ACCOUNT_ID, operation_key: "disabled", mail: mail) }
  end

  def test_event_before_acceptance_replays_with_indexed_normalized_message_id
    receipt = Events.record(event)
    assert_equal "unmatched", receipt.state
    assert_equal "provider@example.com", receipt.message_id
    delivery = accept(prepare)
    assert_nil delivery.outbound_recipients.first.occurred_at
    calls = 0
    assert_equal 1, Events.replay(account_id: ACCOUNT_ID, message_id: "<provider@example.com>") { calls += 1 }
    assert_equal 1, calls
    assert_equal "delivered", delivery.outbound_recipients.first.reload.state
    assert_equal "applied", receipt.reload.state
    assert_equal 0, Events.replay(account_id: ACCOUNT_ID, message_id: "provider@example.com")
  end

  def test_older_and_unknown_events_do_not_overwrite_terminal_state
    delivery = accept(prepare)
    Events.record(event)
    calls = 0
    receipt = Events.record(event(id: "deferred", status: "deferred", time: "2026-09-11T00:00:00Z")) { calls += 1 }
    assert_equal "applied", receipt.state
    assert_equal 0, calls
    assert_equal "delivered", delivery.outbound_recipients.first.reload.state
    assert_equal "unmatched", Events.record(event(id: "future", status: "future")).state
    assert_raises(Cloudflare::Email::ValidationError) { Events.record(event(id: "bad", time: nil)) }
    assert_nil Receipt.find_by(event_id: "bad")
  end

  def test_lifecycle_event_resolves_an_omitted_recipient_without_losing_acceptance_evidence
    delivery = prepare(recipients: ["Recipient@example.net", "second@example.net"])
    stub_request(:post, send_raw_endpoint).to_return(body: JSON.generate(success: true,
      result: { message_id: "provider@example.com", queued: ["Recipient@example.net"] }))
    Outbox.deliver(delivery, client: make_client)
    assert_equal "partial", delivery.state
    Events.record(event(recipient: "second@example.net", status: "bounced"))
    assert_equal "accepted", delivery.reload.state
    recipient = delivery.outbound_recipients.find_by!(recipient: "second@example.net")
    assert_equal "accepted", recipient.acceptance_state
    assert_equal "bounced", recipient.state
    assert recipient.terminal?
    Outbox.deliver(delivery, client: make_client)
    assert_requested :post, send_raw_endpoint, times: 1
  end

  def test_generated_migrations_refuse_to_erase_delivery_and_deduplication_evidence
    delivery = prepare
    receipt = Events.record(event)
    assert_raises(ActiveRecord::IrreversibleMigration) { CreateCloudflareEmailOutbox.new.migrate(:down) }
    assert_raises(ActiveRecord::IrreversibleMigration) { CreateCloudflareEmailEventReceipts.new.migrate(:down) }
    assert Delivery.exists?(delivery.id)
    assert Receipt.exists?(receipt.id)
  end

  def test_callback_error_rolls_back_product_and_recipient_but_preserves_receipt
    delivery = accept(prepare)
    projection = OutboxProjection.create!(status: "accepted")
    assert_raises(RuntimeError) do
      Events.record(event) do
        projection.update!(status: "delivered")
        raise "product write failed"
      end
    end
    assert_equal "accepted", projection.reload.status
    assert_equal "accepted", delivery.outbound_recipients.first.reload.state
    assert_equal "pending", Receipt.first.state
    Events.replay(account_id: ACCOUNT_ID) { projection.update!(status: "delivered") }
    assert_equal "delivered", projection.reload.status
  end

  def test_job_retry_repairs_failed_product_projection_without_resending
    delivery = prepare
    stub_request(:post, send_raw_endpoint).to_return(body: JSON.generate(success: true,
      result: { message_id: "provider@example.com" }))
    projection = OutboxProjection.create!(status: "draft")
    settings = Struct.new(:outbox_delivery_handler, :outbox_client_options, :outbox_recipient_handler, keyword_init: true).new(outbox_delivery_handler: ->(_) {
      projection.update!(status: "sent")
      raise "projection unavailable"
    })
    job = Job.new
    Cloudflare::Email::Credentials.stub(:account_id, ACCOUNT_ID) do
      Cloudflare::Email::Credentials.stub(:api_token, API_TOKEN) do
        job.stub(:settings, settings) { assert_raises(RuntimeError) { job.perform(ACCOUNT_ID, "operation") } }
        assert_equal "accepted", delivery.reload.state
        assert_equal "draft", projection.reload.status
        settings.outbox_delivery_handler = ->(_) { projection.update!(status: "sent") }
        job.stub(:settings, settings) { job.perform(ACCOUNT_ID, "operation") }
      end
    end
    assert_equal "sent", projection.reload.status
    assert_requested :post, send_raw_endpoint, times: 1
  end

  def test_job_arguments_only_contain_operation_identity
    Job.queue_adapter = :test
    Job.perform_later(ACCOUNT_ID, "operation")
    data = Job.queue_adapter.enqueued_jobs.last
    assert_equal [ACCOUNT_ID, "operation"], data[:args]
    serialized = JSON.generate(Job.new(ACCOUNT_ID, "operation").serialize)
    refute serialized.include?("mime_message")
    refute serialized.include?(API_TOKEN)
  end

  def test_notifications_expose_operation_outcome_without_message_content
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe(/cloudflare_email\.outbox_/) { |*args| captured << args.last }
    delivery = accept(prepare)
    assert_equal %w[prepared accepted], captured.map { |payload| payload[:state] }
    assert_equal [delivery.id], captured.map { |payload| payload[:delivery_id] }.uniq
    assert captured.all? { |payload| payload[:account_id] == ACCOUNT_ID }
    refute captured.any? { |payload| payload.key?(:mime_message) || payload.key?(:recipients) || payload.key?(:api_token) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
