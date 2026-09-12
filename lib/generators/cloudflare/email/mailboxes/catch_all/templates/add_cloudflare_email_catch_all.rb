class AddCloudflareEmailCatchAll < ActiveRecord::Migration[7.1]
  def up
    unless column_exists?(:cloudflare_email_addresses, :catch_all)
      add_column :cloudflare_email_addresses, :catch_all, :boolean, null: false, default: false
    end
    unless column_exists?(:cloudflare_email_addresses, :catch_all_evidence)
      add_column :cloudflare_email_addresses, :catch_all_evidence, :text
    end
    unless index_exists?(:cloudflare_email_addresses, name: "idx_cf_email_domain_catch_all")
      add_index :cloudflare_email_addresses, :receiving_domain_id, unique: true,
        where: "catch_all = TRUE AND state = 'active'", name: "idx_cf_email_domain_catch_all"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Disable catch-all receiving before an explicit forward schema change"
  end
end
