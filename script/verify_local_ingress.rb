# Run from the repository root:
# BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile bundle install
# BUNDLE_GEMFILE=gemfiles/local_ingress.gemfile NODE_BINARY=/path/to/node22 bundle exec ruby script/verify_local_ingress.rb
# Install Worker tooling first with Node 22+: npm ci --prefix templates/worker
# Uses only synthetic messages, temporary storage, and loopback HTTP servers.
require "tmpdir"
require "fileutils"
require "socket"
require "net/http"
require "json"
require "base64"
require "rackup/handler/webrick"
require "rails"
require "action_controller/railtie"
require "action_mailer/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "action_mailbox/engine"

REPO_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(REPO_ROOT, "lib")
require "cloudflare-email"

LOCAL_ROOT = Dir.mktmpdir("cloudflare-email-local-ingress")
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3:#{LOCAL_ROOT}/test.sqlite3"
ENV["CLOUDFLARE_INGRESS_SECRET"] = "synthetic-local-ingress-secret"
FileUtils.mkdir_p("#{LOCAL_ROOT}/config")

class LocalIngressApp < Rails::Application
  config.root = LOCAL_ROOT
  config.eager_load = false
  config.secret_key_base = "synthetic-local-test-" * 8
  config.hosts = ["127.0.0.1", "localhost"]
  config.logger = Logger.new(File::NULL)
  config.active_job.queue_adapter = :test
  config.action_mailbox.ingress = :cloudflare
  config.active_storage.service = :test
  config.active_storage.service_configurations = {
    test: { service: "Disk", root: "#{LOCAL_ROOT}/storage" },
  }
end

LocalIngressApp.initialize!
ActiveRecord::Migration.verbose = false
%w[activestorage actionmailbox].each do |gem_name|
  Dir["#{Gem.loaded_specs.fetch(gem_name).full_gem_path}/db/migrate/*.rb"].each { |file| require file }
end
CreateActiveStorageTables.new.migrate(:up)
CreateActionMailboxTables.new.migrate(:up)

class ApplicationMailbox < ActionMailbox::Base
  routing all: :capture
end

class CaptureMailbox < ApplicationMailbox
  class_attribute :received_attachment
  def process
    self.class.received_attachment = mail.attachments.first.decoded
  end
end

def available_port
  TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
end

def check(condition, description)
  raise "FAIL: #{description}" unless condition
  puts "PASS: #{description}"
end

def http_request(port, body: nil)
  path = body ? "/cdn-cgi/local/email?from=sender@example.test&to=inbox@example.test" : "/"
  request = body ? Net::HTTP::Post.new(path) : Net::HTTP::Get.new(path)
  if body
    request["Content-Type"] = "message/rfc822"
    request.body = body
  end
  Net::HTTP.start("127.0.0.1", port, nil, nil, nil, nil, open_timeout: 1, read_timeout: 20) { |http| http.request(request) }
end

def wait_for_http(port, process: nil)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  loop do
    if process && Process.waitpid(process, Process::WNOHANG)
      raise "local Wrangler exited before becoming ready"
    end
    begin
      return http_request(port)
    rescue Errno::ECONNREFUSED, Net::ReadTimeout, EOFError
      raise "local server did not become ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
    end
  end
end

def stop_process(pid)
  return unless pid
  Process.kill("TERM", -pid)
  Process.waitpid(pid)
rescue Errno::ESRCH, Errno::ECHILD
end

rails_server = nil
rails_thread = nil
worker_pid = nil
begin
  rails_port = available_port
  redirect_followed = false
  local_app = lambda do |env|
    case env["PATH_INFO"]
    when "/test-redirect"
      [302, { "location" => "http://127.0.0.1:#{rails_port}/test-redirect-target" }, []]
    when "/test-redirect-target"
      redirect_followed = true
      [200, {}, ["redirect target"]]
    when "/test-slow"
      sleep 17
      [200, {}, ["slow test response"]]
    else
      Rails.application.call(env)
    end
  end
  rails_thread = Thread.new do
    Rackup::Handler::WEBrick.run(local_app, Host: "127.0.0.1", Port: rails_port,
      AccessLog: [], Logger: WEBrick::Log.new(File::NULL)) { |server| rails_server = server }
  end
  wait_for_http(rails_port)

  node = ENV.fetch("NODE_BINARY", "node")
  wrangler = File.join(REPO_ROOT, "templates/worker/node_modules/wrangler/bin/wrangler.js")
  raise "Run npm ci in templates/worker first" unless File.file?(wrangler)
  puts "Ruby #{RUBY_VERSION}; Rails #{Rails.version}"
  system(node, "--version", exception: true)
  worker_source = File.join(REPO_ROOT, "templates/worker/src/index.js")
  worker_port = available_port
  File.write("#{LOCAL_ROOT}/wrangler.json", JSON.generate(
    name: "cloudflare-email-local-verification", main: worker_source,
    compatibility_date: "2026-09-10", observability: { enabled: false },
  ))

  attachment = (0..255).to_a.pack("C*") + "\x00\xff\r\n".b
  mime = [
    "From: sender@example.test", "To: inbox@example.test",
    "Message-ID: <workerd-local-verification@example.test>", "Subject: Synthetic local runtime test",
    "MIME-Version: 1.0", 'Content-Type: multipart/mixed; boundary="local-boundary"', "",
    "--local-boundary", "Content-Type: text/plain; charset=utf-8", "", "Synthetic message.",
    "--local-boundary", 'Content-Type: application/octet-stream; name="fixture.bin"',
    'Content-Disposition: attachment; filename="fixture.bin"', "Content-Transfer-Encoding: base64", "",
    Base64.strict_encode64(attachment), "--local-boundary--", "",
  ].join("\r\n")

  ["valid", "wrong_secret", "missing_secret", "redirect", "timeout"].each do |scenario|
    path = { "redirect" => "/test-redirect", "timeout" => "/test-slow" }.fetch(scenario,
      "/rails/action_mailbox/cloudflare/inbound_emails")
    secrets = "RAILS_INGRESS_URL=http://127.0.0.1:#{rails_port}#{path}\n"
    secrets += "INGRESS_SECRET=#{scenario == 'valid' ? ENV.fetch('CLOUDFLARE_INGRESS_SECRET') : 'synthetic-misconfiguration'}\n" unless scenario == "missing_secret"
    File.write("#{LOCAL_ROOT}/.dev.vars", secrets, perm: 0o600)
    log_path = "#{LOCAL_ROOT}/wrangler-#{scenario}.log"
    worker_pid = Process.spawn({ "WRANGLER_SEND_METRICS" => "false", "CI" => "true",
      "CLOUDFLARE_API_TOKEN" => nil, "CLOUDFLARE_ACCOUNT_ID" => nil },
      node, wrangler, "dev", "--local", "--config", "#{LOCAL_ROOT}/wrangler.json",
      "--ip", "127.0.0.1", "--port", worker_port.to_s, "--inspector-port", "0",
      chdir: LOCAL_ROOT, out: log_path, err: [:child, :out], pgroup: true)
    begin
      wait_for_http(worker_port, process: worker_pid)
      before = ActionMailbox::InboundEmail.count
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scenario_mime = scenario == "valid" ? mime : mime.sub("workerd-local-verification@", "#{scenario}@")
      response = http_request(worker_port, body: scenario_mime)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      puts "#{scenario}: local simulator HTTP #{response.code}: #{response.body.strip}"
      if scenario == "valid"
        check(response.is_a?(Net::HTTPSuccess), "workerd accepts valid synthetic email")
        check(ActionMailbox::InboundEmail.count == before + 1, "real Rails ingress persists exactly one message")
        inbound = ActionMailbox::InboundEmail.last
        check(inbound.raw_email.download == mime, "raw RFC822 bytes survive workerd-to-Rails HTTP unchanged")
        check(inbound.mail.attachments.first.decoded == attachment, "all 256 binary byte values survive attachment delivery")
        duplicate = http_request(worker_port, body: mime)
        check(duplicate.is_a?(Net::HTTPSuccess) && ActionMailbox::InboundEmail.count == before + 1,
          "duplicate delivery is accepted without another inbound record")
        ActionMailbox::RoutingJob.perform_now(inbound)
        check(inbound.reload.delivered? && CaptureMailbox.received_attachment == attachment,
          "real routing job executes mailbox and receives intact attachment")
      else
        check(ActionMailbox::InboundEmail.count == before, "#{scenario} configuration does not persist mail")
        check(response.code == "400" && response.body.include?("Worker rejected email"),
          "#{scenario} reports rejection to local simulator")
        if scenario == "redirect"
          check(response.body.include?("upstream returned 302") && !redirect_followed,
            "workerd refuses redirect without contacting redirect target")
        elsif scenario == "timeout"
          check(response.body.include?("upstream fetch timed out") && elapsed.between?(14, 20),
            "workerd aborts stalled ingress after 15 seconds (#{elapsed.round(2)}s)")
        end
      end
    rescue => error
      warn File.read(log_path)
      raise error
    ensure
      stop_process(worker_pid)
      worker_pid = nil
    end
  end
  puts "Local workerd-to-Rails verification complete. No email sent and no Worker deployed."
ensure
  stop_process(worker_pid)
  rails_server&.shutdown
  rails_thread&.join(5)
  FileUtils.remove_entry(LOCAL_ROOT) if File.exist?(LOCAL_ROOT)
end
