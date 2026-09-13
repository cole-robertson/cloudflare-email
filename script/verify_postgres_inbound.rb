# POSTGRES_TEST_URL must name a disposable test database. Each run creates and
# drops its own schema, including when its child fixture fails.
require "pg"
require "securerandom"
require "uri"
require "rbconfig"

url = ENV.fetch("POSTGRES_TEST_URL")
schema = "mailbox_kit_verify_#{SecureRandom.hex(8)}"
connection = PG.connect(url)
connection.exec("CREATE SCHEMA #{schema}")
begin
  uri = URI.parse(url)
  parameters = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == "schema_search_path" }
  uri.query = URI.encode_www_form(parameters + [["schema_search_path", schema]])
  success = system({ "MAILBOX_KIT_ONLY" => "1", "MAILBOX_KIT_POSTGRES_URL" => uri.to_s },
    RbConfig.ruby, File.expand_path("../test/support/management_engine.rb", __dir__))
  abort "PostgreSQL inbound verification failed" unless success
ensure
  connection.exec("DROP SCHEMA #{schema} CASCADE")
  connection.close
end
