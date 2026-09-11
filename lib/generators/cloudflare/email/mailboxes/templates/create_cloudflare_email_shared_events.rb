class CreateCloudflareEmailSharedEvents < ActiveRecord::Migration[7.2]
  def up
    create_table :cloudflare_email_shared_event_receipts do |t|
      t.string :account_id, null: false
      t.string :event_id, null: false
      t.string :message_id, null: false
      t.string :recipient, null: false
      t.text :payload_json, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :applied_at
      t.timestamps
    end
    add_index :cloudflare_email_shared_event_receipts, [:account_id, :event_id], unique: true,
      name: "idx_cf_shared_events_identity"
    add_index :cloudflare_email_shared_event_receipts, [:state, :id], name: "idx_cf_shared_events_replay"

    create_table :cloudflare_email_provider_correlations do |t|
      t.string :account_id, null: false
      t.string :message_id, null: false
      t.string :recipient, null: false
      t.string :tenant_key, null: false
      t.bigint :outbound_delivery_id, null: false
      t.timestamps
    end
    add_index :cloudflare_email_provider_correlations,
      [:account_id, :message_id, :recipient, :tenant_key, :outbound_delivery_id], unique: true,
      name: "idx_cf_provider_correlations_identity"
    add_index :cloudflare_email_provider_correlations, [:account_id, :message_id, :recipient],
      name: "idx_cf_provider_correlations_lookup"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve tenant routing and event deduplication evidence; use a forward fix"
  end
end
