require "bundler/setup"
require "minitest/autorun"
require "active_record"
require "tmpdir"
require "generators/cloudflare/email/mailboxes/mailboxes_generator"
require "generators/cloudflare/email/mailboxes/catch_all/catch_all_generator"

class MailboxGeneratorInstallationTest < Minitest::Test
  Generator = Cloudflare::Email::Generators::MailboxesGenerator

  def test_fresh_single_database_install
    Dir.mktmpdir do |dir|
      Generator.start(["--quiet"], destination_root: dir)
      files = Dir.glob(File.join(dir, "db/migrate/*.rb"))
      assert_equal 5, files.length
      assert_equal 5, files.map { |path| File.basename(path).split("_").first }.uniq.length
      migrate(File.join(dir, "db/migrate"), File.join(dir, "single.sqlite3"))
      assert ActiveRecord::Base.connection.table_exists?(:cloudflare_email_mailbox_messages)
      assert ActiveRecord::Base.connection.table_exists?(:cloudflare_email_provider_correlations)
      assert ActiveRecord::Base.connection.table_exists?(:cloudflare_email_event_receipts)
      assert ActiveRecord::Base.connection.column_exists?(:cloudflare_email_addresses, :catch_all, :boolean)
      assert ActiveRecord::Base.connection.index_exists?(:cloudflare_email_addresses, name: "idx_cf_email_domain_catch_all")
      names = Dir.glob(File.join(dir, "config/initializers/*.rb")).sort.map { |path| File.basename(path) }
      assert_equal "00_cloudflare_email_tenancy.rb", names.first
      # Ruby source in every generated initializer parses successfully.
      names.each do |name|
        RubyVM::InstructionSequence.compile_file(File.join(dir, "config/initializers", name))
      end
    end
  end

  def test_separate_directory_and_tenant_database_install
    Dir.mktmpdir do |dir|
      Generator.start(["--quiet", "--tenant-migrations-path=db/tenant_migrate",
        "--directory-migrations-path=db/directory_migrate"], destination_root: dir)
      assert_equal 3, Dir.glob(File.join(dir, "db/tenant_migrate/*.rb")).length
      assert_equal 2, Dir.glob(File.join(dir, "db/directory_migrate/*.rb")).length
      migrate(File.join(dir, "db/directory_migrate"), File.join(dir, "directory.sqlite3"))
      assert ActiveRecord::Base.connection.table_exists?(:cloudflare_email_receiving_domains)
      refute ActiveRecord::Base.connection.table_exists?(:cloudflare_email_mailboxes)
      migrate(File.join(dir, "db/tenant_migrate"), File.join(dir, "tenant.sqlite3"))
      assert ActiveRecord::Base.connection.table_exists?(:cloudflare_email_mailboxes)
      assert ActiveRecord::Base.connection.table_exists?(:cloudflare_email_outbound_deliveries)
      refute ActiveRecord::Base.connection.table_exists?(:cloudflare_email_receiving_domains)
    end
  end

  def test_optional_upgrade_preserves_existing_addresses_and_does_not_enable_catch_all
    Dir.mktmpdir do |dir|
      Generator.start(["--quiet", "--tenant-migrations-path=db/tenant_migrate",
        "--directory-migrations-path=db/directory_migrate"], destination_root: dir)
      path = File.join(dir, "db/tenant_migrate")
      database = File.join(dir, "tenant.sqlite3")
      migrate(path, database)
      connection = ActiveRecord::Base.connection
      connection.remove_index(:cloudflare_email_addresses, name: "idx_cf_email_domain_catch_all")
      connection.remove_column(:cloudflare_email_addresses, :catch_all)
      connection.remove_column(:cloudflare_email_addresses, :catch_all_evidence)
      connection.execute("INSERT INTO cloudflare_email_mailboxes (id, tenant_key, name, created_at, updated_at) VALUES (1, 'one', 'Existing', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      connection.execute("INSERT INTO cloudflare_email_addresses (tenant_key, mailbox_id, receiving_domain_id, local_part, domain, address, state, created_at, updated_at) VALUES ('one', 1, 9, 'old', 'example.com', 'old@example.com', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
      Cloudflare::Email::Generators::CatchAllGenerator.start(["--quiet", "--tenant-migrations-path=db/tenant_migrate"], destination_root: dir)
      assert_equal 4, Dir.glob(File.join(path, "*.rb")).length
      migrate(path, database)
      record = ActiveRecord::Base.connection.select_one("SELECT * FROM cloudflare_email_addresses")
      assert_equal "old@example.com", record.fetch("address")
      assert_equal 0, record.fetch("catch_all")
      assert_nil record.fetch("catch_all_evidence")
      assert ActiveRecord::Base.connection.index_exists?(:cloudflare_email_addresses, name: "idx_cf_email_domain_catch_all")
      AddCloudflareEmailCatchAll.new.migrate(:up)
      assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM cloudflare_email_addresses")
    end
  end

  private

  def migrate(path, database)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database)
    ActiveRecord::Migration.verbose = false
    ActiveRecord::MigrationContext.new(path).migrate
  end
end
