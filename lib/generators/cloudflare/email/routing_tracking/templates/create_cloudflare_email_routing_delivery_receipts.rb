class CreateCloudflareEmailRoutingDeliveryReceipts < ActiveRecord::Migration[7.1]
  def up
    create_table :cloudflare_email_routing_delivery_receipts do |t|
      t.references :outbound_delivery, null: false, index: {name: "idx_cf_routing_delivery"},
        foreign_key: {to_table: :cloudflare_email_outbound_deliveries}
      t.string :account_id, null: false
      t.string :zone_id, null: false
      t.string :event_key, null: false
      t.text :payload_json, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :received_at, null: false
      t.datetime :applied_at
      t.timestamps
    end
    add_index :cloudflare_email_routing_delivery_receipts, [:account_id, :event_key], unique: true, name: "idx_cf_routing_identity"
    add_index :cloudflare_email_routing_delivery_receipts, [:account_id, :state, :id], name: "idx_cf_routing_replay"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve authentic delivery evidence; use a forward fix or a reconciled backup"
  end
end
