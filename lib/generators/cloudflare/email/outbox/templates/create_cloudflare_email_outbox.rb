class CreateCloudflareEmailOutbox < ActiveRecord::Migration[7.1]
  def up
    create_table :cloudflare_email_outbound_deliveries do |t|
      t.string :account_id, null: false
      t.string :operation_key, null: false
      t.string :from_address, null: false
      t.text :recipients_json, null: false
      t.binary :mime_message, null: false
      t.string :snapshot_digest, null: false
      t.string :state, null: false, default: "prepared"
      t.string :provider_message_id
      t.text :response_json
      t.string :error_class
      t.datetime :request_started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :cloudflare_email_outbound_deliveries, [:account_id, :operation_key], unique: true, name: "idx_cf_email_outbound_operation"
    add_index :cloudflare_email_outbound_deliveries, [:account_id, :provider_message_id], name: "idx_cf_email_outbound_provider"
    add_index :cloudflare_email_outbound_deliveries, [:state, :id], name: "idx_cf_email_outbound_pending"

    create_table :cloudflare_email_outbound_recipients do |t|
      t.references :outbound_delivery, null: false, index: false, foreign_key: { to_table: :cloudflare_email_outbound_deliveries }
      t.string :recipient, null: false
      t.string :state, null: false, default: "prepared"
      t.string :acceptance_state, null: false, default: "prepared"
      t.datetime :occurred_at
      t.boolean :terminal, null: false, default: false
      t.timestamps
    end
    add_index :cloudflare_email_outbound_recipients, [:outbound_delivery_id, :recipient], unique: true, name: "idx_cf_email_outbound_recipient"

    create_table :cloudflare_email_outbound_reconciliations do |t|
      t.references :outbound_delivery, null: false, index: { name: "idx_cf_email_reconciliation_delivery" }, foreign_key: { to_table: :cloudflare_email_outbound_deliveries }
      t.string :actor, null: false
      t.text :reason, null: false
      t.text :evidence, null: false
      t.string :outcome, null: false
      t.string :provider_message_id
      t.text :recipients_json
      t.timestamps
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve delivery evidence; use a forward fix or a reconciled backup"
  end
end
