# frozen_string_literal: true

# Run with the inbox bundle; never connects to the configured application DB.
# INBOX_ROOT=/path/to/inbox BUNDLE_GEMFILE=/path/to/inbox/Gemfile bundle exec ruby script/verification/install_upgrade.rb
require "tmpdir"
require "fileutils"
require "json"

app_root = File.realpath(ENV.fetch("INBOX_ROOT"))
checks = []
check = lambda do |condition, name|
  raise "FAIL: #{name}" unless condition
  checks << name
  puts "PASS: #{name}"
end

Dir.mktmpdir("cloudflare-email-upgrade-") do |temporary|
  ENV["RAILS_ENV"] = "test"
  ENV["DATABASE_URL"] = "sqlite3:#{temporary}/upgrade.sqlite3"
  ENV["SECRET_KEY_BASE"] = "isolated-upgrade-test-" * 8
  ENV["CLOUDFLARE_INGRESS_SECRET"] = "isolated-upgrade-ingress"
  ENV.delete("RAILS_MASTER_KEY")
  Dir.chdir(app_root)
  require File.join(app_root, "config/application")
  Rails.application.config.credentials.content_path = File.join(temporary, "unused.yml.enc")
  Rails.application.config.credentials.key_path = File.join(temporary, "unused.key")
  Rails.application.config.logger = ActiveSupport::Logger.new(File.join(temporary, "rails.log"))
  Rails.application.initialize!
  ActiveJob::Base.queue_adapter = :test
  ActionMailbox.ingress = :cloudflare
  ActionMailer::Base.perform_deliveries = false
  storage = {"isolated" => {"service" => "Disk", "root" => File.join(temporary, "storage")}}
  ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(storage)
  ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch("isolated")

  ActiveRecord::Migration.verbose = false
  migration_path = File.join(app_root, "db/migrate")
  context = -> { ActiveRecord::MigrationContext.new(migration_path) }
  baseline = 20260418012251
  context.call.migrate(baseline)
  connection = ActiveRecord::Base.connection
  check.call(!connection.column_exists?(:messages, :delivery_state), "clean baseline schema predates delivery ledger")

  # Raw SQL deliberately avoids new-model defaults against the old schema.
  connection.execute("INSERT INTO users (id,name,email,password_digest,created_at,updated_at) VALUES (1,'Fixture','owner@example.test','unused',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  connection.execute("INSERT INTO mailboxes (id,user_id,address) VALUES (1,1,'inbox@example.test')")
  connection.execute("INSERT INTO folders (id,mailbox_id,name,kind,created_at,updated_at) VALUES (1,1,'Inbox','inbox',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  connection.execute("INSERT INTO conversations (id,mailbox_id,folder_id,thread_id,sender_email,subject,status,created_at,updated_at) VALUES (1,1,1,'upgrade-fixture','sender@example.test','Upgrade','closed',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  connection.execute("INSERT INTO messages (id,conversation_id,role,body,message_id,drafted,created_at,updated_at) VALUES (1,1,'user','Preserved incoming','legacy-incoming@example.test',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  connection.execute("INSERT INTO messages (id,conversation_id,role,body,message_id,drafted,sent_at,created_at,updated_at) VALUES (2,1,'assistant','Preserved sent reply','legacy-sent@example.test',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  connection.execute("INSERT INTO messages (id,conversation_id,role,body,drafted,created_at,updated_at) VALUES (3,1,'assistant','Preserved unapproved draft',1,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  original_columns = connection.columns(:messages).map(&:name)
  original_rows = connection.select_all("SELECT #{original_columns.join(',')} FROM messages ORDER BY id").to_a
  preserved = -> { connection.select_all("SELECT #{original_columns.join(',')} FROM messages ORDER BY id").to_a == original_rows }

  context.call.migrate
  check.call(preserved.call, "upgrade preserves every original message column and timestamp")
  check.call(connection.select_rows("SELECT id,delivery_state FROM messages ORDER BY id") == [[1, "pending"], [2, "legacy_sent"], [3, "pending"]], "upgrade marks old sends legacy_sent without inventing provider acceptance")
  check.call(connection.select_value("SELECT COUNT(*) FROM delivery_attempts").zero?, "upgrade creates no fabricated delivery attempts")
  check.call(connection.select_value("SELECT COUNT(*) FROM messages WHERE draft_review_required = 0 AND draft_review_reasons = '[]'") == 3, "existing rows receive valid draft review defaults")

  # Model a request lost during a process crash, then exercise backup recovery.
  connection.execute("UPDATE messages SET delivery_state = 'unknown' WHERE id = 3")
  connection.execute("INSERT INTO delivery_attempts (id,message_id,state,recipient,body,request_started_at,created_at,updated_at) VALUES (1,3,'unknown','sender@example.test','Preserved unapproved draft',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
  backup = File.join(temporary, "before-rollback.sqlite3")
  connection.execute("VACUUM INTO #{connection.quote(backup)}")
  context.call.migrate(baseline)
  check.call(preserved.call && !connection.table_exists?(:delivery_attempts), "schema rollback preserves legacy messages but removes the durable attempt ledger")
  context.call.migrate
  check.call(preserved.call && connection.select_value("SELECT COUNT(*) FROM delivery_attempts").zero?, "schema reapply succeeds but cannot recover dropped attempt history")

  ActiveRecord::Base.connection_pool.disconnect!
  restored = File.join(temporary, "restored.sqlite3")
  FileUtils.cp(backup, restored)
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: restored)
  connection = ActiveRecord::Base.connection
  check.call(connection.select_value("SELECT state FROM delivery_attempts WHERE id = 1") == "unknown" && connection.select_value("SELECT delivery_state FROM messages WHERE id = 3") == "unknown", "quiesced SQLite backup restores ambiguous attempt and blocked message state")
  context.call.migrate
  check.call(connection.select_value("SELECT COUNT(*) FROM delivery_attempts") == 1, "migrating restored current schema is idempotent")

  # Exercise strict v2 ingress and mailbox routing, rejecting old Worker traffic.
  # Closed conversation avoids all LLM calls and outbound delivery.
  require "rack/mock"
  require "cloudflare/email/verification"
  require "cloudflare/email/envelope"
  require "webmock"
  WebMock.enable!
  WebMock.disable_net_connect!
  [Message, Conversation, ActionMailbox::InboundEmail, ActiveStorage::Blob].each(&:reset_column_information)
  blocked = false
  begin
    DraftDelivery.call(Message.find(3))
  rescue DraftDelivery::Error => error
    blocked = error.message.include?("reconciliation")
  end
  check.call(blocked && DeliveryAttempt.count == 1, "restored ambiguous send remains blocked without creating another attempt")
  request = Rack::MockRequest.new(Rails.application)
  deliver = lambda do |name, version:, cc: false|
    body = "From: sender@example.test\r\nTo: inbox@example.test\r\n"
    body += "Cc: cc@example.test\r\n" if cc
    body += "Message-ID: <#{name}@example.test>\r\nIn-Reply-To: <legacy-incoming@example.test>\r\nSubject: Re: Upgrade\r\n\r\nSynthetic rollout message\r\n"
    timestamp = Time.now.to_i.to_s
    envelope = Cloudflare::Email::Envelope.encode(from: "sender@example.test", to: "inbox@example.test")
    signature = if version == "2"
      Cloudflare::Email::Verification.sign(secret: ENV.fetch("CLOUDFLARE_INGRESS_SECRET"), body: body, timestamp: timestamp, envelope: envelope)
    else
      Cloudflare::Email::Signing.hmac_hex(ENV.fetch("CLOUDFLARE_INGRESS_SECRET"), "#{timestamp}.".b + body.b)
    end
    headers = {"CONTENT_TYPE" => "message/rfc822", "HTTP_X_CF_EMAIL_TIMESTAMP" => timestamp, "HTTP_X_CF_EMAIL_SIGNATURE" => signature}
    headers["HTTP_X_CF_EMAIL_SIGNATURE_VERSION"] = version if version
    headers["HTTP_X_CF_EMAIL_ENVELOPE"] = envelope if envelope
    before = ActionMailbox::InboundEmail.count
    response = request.post("/rails/action_mailbox/cloudflare/inbound_emails", input: body, **headers)
    unless version == "2"
      next response.status == 401 && ActionMailbox::InboundEmail.count == before
    end
    raise "Ingress failed: #{response.status}" unless response.status == 200
    inbound = ActionMailbox::InboundEmail.find_by!(message_id: "#{name}@example.test")
    inbound.route
    inbound.reload
  end
  check.call(deliver.call("missing-version", version: nil), "old Worker without a version is rejected before persistence")
  check.call(deliver.call("v1-cc", version: "1", cc: true), "v1 Worker with Cc is rejected before persistence")
  check.call(deliver.call("v1-strict", version: "1"), "v1 Worker with a single recipient is rejected before persistence")
  check.call(deliver.call("v2-strict", version: "2").delivered?, "current Worker v2 routes through the authenticated envelope")
  check.call(Message.where(conversation_id: 1, role: "user").count == 2, "only the authenticated v2 message enters the existing conversation")
  check.call(ActionMailer::Base.deliveries.empty?, "rollout rehearsal sends no outbound mail")

  puts JSON.pretty_generate({ruby: RUBY_VERSION, rails: Rails.version, gem: Cloudflare::Email::VERSION, checks: checks, isolation: "temporary SQLite databases and Active Storage; network disabled during routing"})
ensure
  ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord::Base)
end
