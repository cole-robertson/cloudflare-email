class CreateCloudflareEmailMailboxes < ActiveRecord::Migration[7.1]
  def up
    create_table :cloudflare_email_mailboxes do |t|
      t.string :tenant_key, null: false
      t.string :name, null: false
      t.string :owner_ref
      t.string :state, null: false, default: "active"
      t.timestamps
    end
    add_index :cloudflare_email_mailboxes, [:tenant_key, :owner_ref], name: "idx_cf_email_mailbox_owner"

    create_table :cloudflare_email_addresses do |t|
      t.string :tenant_key, null: false
      t.references :mailbox, null: false, index: false, foreign_key: { to_table: :cloudflare_email_mailboxes }
      # The domain directory can live in another database: no cross-database FK.
      t.bigint :receiving_domain_id, null: false
      t.string :local_part, null: false
      t.string :domain, null: false
      t.string :address, null: false
      t.string :state, null: false, default: "pending"
      t.text :provisioning_evidence
      t.timestamps
    end
    add_index :cloudflare_email_addresses, :address, unique: true, name: "idx_cf_email_mailbox_address"
    add_index :cloudflare_email_addresses, :mailbox_id, name: "idx_cf_email_address_mailbox"

    create_table :cloudflare_email_mailbox_messages do |t|
      t.string :tenant_key, null: false
      t.references :mailbox, null: false, index: false, foreign_key: { to_table: :cloudflare_email_mailboxes }
      # No database FK to the optional Rails table; the ingress service requires
      # the same connection and manages membership+raw source atomically.
      t.bigint :inbound_email_id, null: false
      t.string :recipient, null: false
      t.datetime :read_at
      t.datetime :archived_at
      t.timestamps
    end
    add_index :cloudflare_email_mailbox_messages, [:mailbox_id, :inbound_email_id], unique: true, name: "idx_cf_email_mailbox_inbound"
    add_index :cloudflare_email_mailbox_messages, [:tenant_key, :mailbox_id, :archived_at, :id], name: "idx_cf_email_mailbox_inbox"

    create_table :cloudflare_email_mailbox_outbound_messages do |t|
      t.string :tenant_key, null: false
      t.references :mailbox, null: false, index: false, foreign_key: { to_table: :cloudflare_email_mailboxes }
      t.references :outbound_delivery, null: false, index: false, foreign_key: { to_table: :cloudflare_email_outbound_deliveries }
      t.timestamps
    end
    add_index :cloudflare_email_mailbox_outbound_messages, :outbound_delivery_id, unique: true, name: "idx_cf_email_mailbox_outbound"
    add_index :cloudflare_email_mailbox_outbound_messages, :mailbox_id, name: "idx_cf_email_outbound_mailbox"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve mailbox ownership and retained messages; use a forward fix"
  end
end
