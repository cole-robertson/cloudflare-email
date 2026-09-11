class CreateCloudflareEmailReceivingDomains < ActiveRecord::Migration[7.1]
  def change
    create_table :cloudflare_email_receiving_domains do |t|
      t.string :domain, null: false
      t.string :tenant_key, null: false
      t.string :account_id, null: false
      t.string :state, null: false, default: "pending"
      t.boolean :sending_enabled, null: false, default: false
      t.text :provisioning_evidence
      t.datetime :verified_at
      t.timestamps
    end
    add_index :cloudflare_email_receiving_domains, :domain, unique: true, name: "idx_cf_email_directory_domain"
    add_index :cloudflare_email_receiving_domains, [:tenant_key, :state], name: "idx_cf_email_directory_tenant"
  end
end
