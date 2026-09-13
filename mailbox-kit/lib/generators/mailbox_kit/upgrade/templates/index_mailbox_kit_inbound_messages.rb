class IndexMailboxKitInboundMessages < ActiveRecord::Migration[7.1]
  def up
    return if index_exists?(:cloudflare_email_mailbox_messages, :inbound_email_id)

    add_index :cloudflare_email_mailbox_messages, :inbound_email_id,
      name: "idx_cf_email_message_inbound"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserve the inbound lookup index; use a forward fix"
  end
end
