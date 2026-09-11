class CreateCloudflareEmailEventReceipts < ActiveRecord::Migration[7.1]
  def change
    create_table :cloudflare_email_event_receipts do |t|
      t.string :account_id, null: false
      t.string :event_id, null: false
      t.string :message_id, null: false
      t.text :payload_json, null: false
      t.string :state, null: false, default: "pending"
      t.datetime :applied_at
      t.timestamps
    end
    add_index :cloudflare_email_event_receipts, [:account_id, :event_id], unique: true,
      name: "idx_cf_email_receipts_account_event"
    add_index :cloudflare_email_event_receipts, [:account_id, :message_id],
      name: "idx_cf_email_receipts_account_message"
    add_index :cloudflare_email_event_receipts, [:state, :id], name: "idx_cf_email_receipts_replay"
  end
end
