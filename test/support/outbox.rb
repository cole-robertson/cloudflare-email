require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "cloudflare/email/active_record/outbox"
require "generators/cloudflare/email/outbox/outbox_generator"

OUTBOX_ROOT = Dir.mktmpdir("cloudflare-email-outbox")
Minitest.after_run { FileUtils.remove_entry(OUTBOX_ROOT) }
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(OUTBOX_ROOT, "outbox.sqlite3"), timeout: 5000, pool: 5)
ActiveRecord::Migration.verbose = false
Cloudflare::Email::Generators::OutboxGenerator.new([], {}, destination_root: OUTBOX_ROOT).invoke_all
require Dir[File.join(OUTBOX_ROOT, "db/migrate/*.rb")].fetch(0)
CreateCloudflareEmailOutbox.new.migrate(:up)

class OutboxTest < Minitest::Test
  Outbox = Cloudflare::Email::ActiveRecord::Outbox
  Delivery = Cloudflare::Email::ActiveRecord::OutboundDelivery
  Recipient = Cloudflare::Email::ActiveRecord::OutboundRecipient
  Reconciliation = Cloudflare::Email::ActiveRecord::OutboundReconciliation
  Client = Struct.new(:account_id, :retry_ambiguous, :handler) do
    def send_raw(**args)
      handler.call(**args)
    end
  end

  def setup
    Reconciliation.delete_all
    Recipient.delete_all
    Delivery.delete_all
  end

  def prepare(**overrides)
    Outbox.prepare(**{ account_id: ACCOUNT_ID, operation_key: "operation", from: "sender@example.com",
      recipients: ["one@example.com", "two@example.com"], mime_message: "Subject: snapshot\r\n\r\nbody\xFF".b }.merge(overrides))
  end

  def client(&block)
    Client.new(ACCOUNT_ID, false, block)
  end

  def response(**result)
    Cloudflare::Email::Response.new(JSON.parse(JSON.generate({ "success" => true, "result" => result })))
  end

  def test_prepare_is_account_scoped_idempotent_and_binary_immutable
    first = prepare
    assert_equal first.id, prepare.id
    assert_equal "\xFF".b, first.mime_message.byteslice(-1, 1)
    assert_equal 2, first.outbound_recipients.count
    assert_raises(Outbox::SnapshotConflict) { prepare(mime_message: "changed") }
    refute_equal first.id, prepare(account_id: "other-account").id
    first.mime_message = "changed"
    begin
      first.save!
    rescue ActiveRecord::ReadonlyAttributeError
      # Rails versions differ on raising versus silently omitting readonly fields.
    end
    assert_equal "\xFF".b, first.reload.mime_message.byteslice(-1, 1)
  end

  def test_prepare_rolls_back_with_application_transaction
    Delivery.transaction do
      prepare
      raise ActiveRecord::Rollback
    end
    assert_equal 0, Delivery.count
    assert_equal 0, Recipient.count
  end

  def test_network_is_never_called_in_ambient_transaction
    delivery = prepare
    Delivery.transaction do
      assert_raises(ArgumentError) { Outbox.deliver(delivery, client: client { flunk "network" }) }
    end
    assert_equal "prepared", delivery.reload.state
  end

  def test_durable_claim_precedes_network_and_repeated_job_does_not_resend
    delivery = prepare
    calls = 0
    provider = client do |**args|
      calls += 1
      refute Delivery.connection.transaction_open?
      assert_equal "sending", Delivery.find(delivery.id).state
      assert_equal delivery.mime_message, args[:mime_message]
      response(message_id: "provider-1")
    end
    2.times { Outbox.deliver(delivery, client: provider) }
    assert_equal 1, calls
    assert_equal "accepted", delivery.reload.state
    assert_equal "provider-1", delivery.provider_message_id
  end

  def test_partial_response_never_resends_successful_recipients
    delivery = prepare
    Outbox.deliver(delivery, client: client { response(delivered: ["one@example.com"], permanent_bounces: ["two@example.com"]) })
    assert_equal "partial", delivery.state
    assert_equal %w[delivered bounced], delivery.outbound_recipients.order(:id).pluck(:state)
    Outbox.deliver(delivery, client: client { flunk "resent partial operation" })
  end

  def test_omitted_recipient_is_unknown_and_conflicting_outcomes_are_not_accepted
    delivery = prepare
    Outbox.deliver(delivery, client: client { response(queued: ["one@example.com"]) })
    assert_equal "partial", delivery.state
    assert_equal %w[queued unknown], delivery.outbound_recipients.order(:id).pluck(:state)
    another = prepare(operation_key: "conflict")
    assert_raises(Cloudflare::Email::ValidationError) do
      Outbox.deliver(another, client: client { response(delivered: ["one@example.com"], permanent_bounces: ["one@example.com"]) })
    end
    assert_equal "unknown", another.reload.state
  end

  def test_network_and_untyped_validation_failures_block_resend
    [Cloudflare::Email::NetworkError.new("lost response"), Cloudflare::Email::ValidationError.new("malformed success"),
      Cloudflare::Email::ServerError.new("server failed", status: 503)].each_with_index do |error, index|
      delivery = prepare(operation_key: "failure-#{index}")
      assert_raises(error.class) { Outbox.deliver(delivery, client: client { raise error }) }
      assert_equal "unknown", delivery.reload.state
      assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "resent" }) }
    end
  end

  def test_explicit_provider_rejection_is_terminal
    delivery = prepare
    assert_raises(Cloudflare::Email::ValidationError) do
      Outbox.deliver(delivery, client: client { raise Cloudflare::Email::ValidationError.new("rejected", status: 400) })
    end
    assert_equal "rejected", delivery.reload.state
    assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "resent" }) }
  end

  def test_wrong_account_and_ambiguous_retry_clients_are_refused_before_claim
    delivery = prepare
    [Client.new("other", false, nil), Client.new(ACCOUNT_ID, true, nil)].each do |provider|
      assert_raises(Cloudflare::Email::ConfigurationError) { Outbox.deliver(delivery, client: provider) }
    end
    assert_equal "prepared", delivery.reload.state
  end

  def test_concurrent_jobs_only_one_network_call
    delivery = prepare
    entered, release = Queue.new, Queue.new
    thread = Thread.new do
      Delivery.connection_pool.with_connection do
        Outbox.deliver(Delivery.find(delivery.id), client: client { entered << true; release.pop; response(message_id: "provider") })
      end
    end
    entered.pop
    assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "second network call" }) }
    release << true
    thread.value
    assert_equal "accepted", delivery.reload.state
  ensure
    release << true if release && thread&.alive?
    thread&.join
  end

  def test_process_death_keeps_durable_claim_and_requires_operator_evidence
    delivery = prepare
    pid = fork do
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(OUTBOX_ROOT, "outbox.sqlite3"), timeout: 5000)
      Outbox.deliver(Delivery.find(delivery.id), client: client { Process.kill("KILL", Process.pid) })
    end
    Process.wait(pid)
    assert_equal "sending", delivery.reload.state
    assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "resent after crash" }) }
    args = { outcome: "not_sent", actor: "operator:1", reason: "checked provider", evidence: "provider logs and worker termination confirmed" }
    assert_raises(Outbox::InvalidTransition) { Outbox.reconcile(delivery, **args, confirm_sender_stopped: true) }
    delivery.update!(request_started_at: Time.now.utc - 901)
    assert_raises(Outbox::InvalidTransition) { Outbox.reconcile(delivery, **args) }
    Outbox.reconcile(delivery, **args, confirm_sender_stopped: true)
    assert_equal "confirmed_not_sent", delivery.state
    assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "old job resend" }) }
  end

  def test_local_persistence_failure_after_acceptance_remains_uncertain
    delivery = prepare
    delivery.define_singleton_method(:update!) { |**_attrs| raise ActiveRecord::StatementInvalid, "database unavailable" }
    assert_raises(ActiveRecord::StatementInvalid) { Outbox.deliver(delivery, client: client { response(message_id: "accepted-provider") }) }
    assert_equal "unknown", delivery.reload.state
    assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "resent after accepted response" }) }
  end

  def test_reconciliation_is_audited_immutable_and_cannot_rewrite_known_recipients
    delivery = prepare
    delivery.update!(state: "unknown")
    Outbox.reconcile(delivery, outcome: "accepted", actor: "operator:1", reason: "provider verified",
      evidence: "ticket 123", provider_message_id: "provider-confirmed", recipients: ["one@example.com"])
    assert_equal "partial", delivery.state
    audit = delivery.outbound_reconciliations.first
    assert_equal "ticket 123", audit.evidence
    assert_raises(ActiveRecord::ReadOnlyRecord) { audit.update!(evidence: "rewrite") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { audit.destroy! }
    assert_raises(ArgumentError) do
      Outbox.reconcile(delivery, outcome: "not_sent", actor: "operator:2", reason: "conflict", evidence: "other ticket", recipients: ["one@example.com"])
    end
    assert_equal 1, Reconciliation.count
  end

  def test_reconciliation_and_application_projection_roll_back_together
    delivery = prepare
    delivery.update!(state: "unknown")
    Delivery.transaction do
      Outbox.reconcile(delivery, outcome: "accepted", actor: "operator", reason: "verified", evidence: "ticket", provider_message_id: "<provider>")
      raise ActiveRecord::Rollback
    end
    assert_equal "unknown", delivery.reload.state
    assert_equal 0, Reconciliation.count
    assert_raises(RuntimeError) do
      Outbox.reconcile(delivery, outcome: "accepted", actor: "operator", reason: "verified", evidence: "ticket", provider_message_id: "<provider>") { raise "app write failed" }
    end
    assert_equal "unknown", delivery.reload.state
    assert_equal 0, Reconciliation.count
  end

  def test_case_normalization_preserves_local_part_and_does_not_invent_event_time
    delivery = prepare(recipients: ["One@EXAMPLE.COM", "One@example.com"])
    assert_equal ["One@example.com"], delivery.recipients
    Outbox.deliver(delivery, client: client { response(delivered: ["One@EXAMPLE.COM"], message_id: "<provider>") })
    assert_equal "accepted", delivery.state
    assert_equal "provider", delivery.provider_message_id
    assert_nil delivery.outbound_recipients.first.occurred_at
    assert delivery.outbound_recipients.first.terminal
  end

  def test_real_client_outbox_request_and_ambiguous_response
    delivery = prepare(mime_message: "Subject: real client\r\n\r\nbody")
    stub_request(:post, send_raw_endpoint).to_return(status: 200, body: JSON.generate({ success: true, result: { message_id: "provider" } }), headers: { "Content-Type" => "application/json" })
    Outbox.deliver(delivery, client: make_client)
    assert_equal "accepted", delivery.state
    assert_requested :post, send_raw_endpoint, times: 1
  end

  def test_malformed_provider_ids_never_prove_acceptance
    [{}, true, 123, "", "<>", "bad id", "<nested<id>>"].each_with_index do |id, index|
      delivery = prepare(operation_key: "bad-id-#{index}")
      assert_raises(Cloudflare::Email::ValidationError) { Outbox.deliver(delivery, client: client { response(message_id: id) }) }
      assert_equal "unknown", delivery.reload.state
      assert_raises(Outbox::InvalidTransition) { Outbox.deliver(delivery, client: client { flunk "resent malformed response" }) }
    end
    delivery = prepare(operation_key: "recipient-proof")
    Outbox.deliver(delivery, client: client { response(delivered: delivery.recipients, message_id: nil) })
    assert_equal "accepted", delivery.state
  end

  def test_conflicting_provider_ids_do_not_cause_false_event_correlation
    [ { delivered: [{ to: "one@example.com", message_id: "one" }, { to: "two@example.com", message_id: "two" }] },
      { message_id: "top", queued: [{ to: "one@example.com", message_id: "other" }] } ].each_with_index do |result, index|
      delivery = prepare(operation_key: "conflicting-ids-#{index}")
      error = assert_raises(Cloudflare::Email::ValidationError) { Outbox.deliver(delivery, client: client { response(**result) }) }
      assert_match(/multiple provider message IDs/, error.message)
      assert_equal "unknown", delivery.reload.state
      assert_nil delivery.provider_message_id
    end
  end

  def test_partial_unknown_recipients_can_be_reconciled_without_rewriting_known_outcomes
    delivery = prepare(recipients: ["one@example.com", "two@example.com", "three@example.com"])
    Outbox.deliver(delivery, client: client { response(message_id: "provider", queued: ["one@example.com"]) })
    audit = { actor: "operator", reason: "provider reviewed", evidence: "ticket" }
    assert_raises(ArgumentError) do
      Outbox.reconcile(delivery, **audit, outcome: "accepted", recipients: ["two@example.com"], provider_message_id: "different")
    end
    Outbox.reconcile(delivery, **audit, outcome: "accepted", recipients: ["two@example.com"], provider_message_id: "<provider>")
    assert_equal %w[queued accepted unknown], delivery.outbound_recipients.order(:id).pluck(:state)
    Outbox.reconcile(delivery, **audit, outcome: "not_sent")
    assert_equal %w[queued accepted not_sent], delivery.outbound_recipients.order(:id).pluck(:state)
    assert_equal "partial", delivery.state
    assert_equal "provider", delivery.provider_message_id
    assert_equal 2, delivery.outbound_reconciliations.count
    assert_raises(ArgumentError) { Outbox.reconcile(delivery, **audit, outcome: "not_sent") }
    Outbox.deliver(delivery, client: client { flunk "partial resent after reconciliation" })
  end

  def test_reconciliation_uses_acceptance_evidence_and_preserves_later_lifecycle
    delivery = prepare
    Outbox.deliver(delivery, client: client { response(message_id: "provider", queued: ["one@example.com"]) })
    first = delivery.outbound_recipients.find_by!(recipient: "one@example.com")
    first.update!(state: "complained", terminal: true, occurred_at: Time.now.utc)
    Outbox.reconcile(delivery, outcome: "accepted", actor: "operator", reason: "verified", evidence: "ticket", provider_message_id: "provider")
    assert_equal "accepted", delivery.state
    assert_equal "complained", first.reload.state
    assert_equal "queued", first.acceptance_state
    assert first.terminal
    assert_equal "accepted", delivery.outbound_recipients.find_by!(recipient: "two@example.com").acceptance_state
  end

  def test_provider_id_in_later_recipient_is_stored_for_event_correlation
    delivery = prepare
    Outbox.deliver(delivery, client: client do
      response(delivered: [{ to: "one@example.com" }, { to: "two@example.com", message_id: "<provider>" }])
    end)
    assert_equal "accepted", delivery.state
    assert_equal "provider", delivery.provider_message_id
  end
end
