require "bundler/setup"
require "minitest/autorun"
require "active_record"
require "tmpdir"
require "generators/cloudflare/email/mailboxes/mailboxes_generator"

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

  private

  def migrate(path, database)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database)
    ActiveRecord::Migration.verbose = false
    ActiveRecord::MigrationContext.new(path).migrate
  end
end
