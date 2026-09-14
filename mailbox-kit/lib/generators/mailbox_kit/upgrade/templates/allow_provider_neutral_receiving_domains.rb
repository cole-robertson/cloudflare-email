class AllowProviderNeutralReceivingDomains < ActiveRecord::Migration[7.1]
  def up
    change_column_null :cloudflare_email_receiving_domains, :account_id, true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Receiving-only domains need no provider account; use a forward fix"
  end
end
