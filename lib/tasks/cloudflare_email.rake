namespace :cloudflare do
  namespace :email do
    desc "Run diagnostics against your Cloudflare Email setup"
    task doctor: :environment do
      require "cloudflare/email/doctor"
      exit Cloudflare::Email::Doctor.call
    end

    desc "Send a test email via the current Cloudflare Email config (TO=addr FROM=addr)"
    task send_test: :environment do
      require "cloudflare/email/send_test"
      exit Cloudflare::Email::SendTest.call(to: ENV["TO"], from: ENV["FROM"])
    end

    desc "Run a cloudflared tunnel pointed at this Rails app, update the Worker's RAILS_INGRESS_URL, and tail logs"
    task dev: :environment do
      require "cloudflare/email/dev_tunnel"
      Cloudflare::Email::DevTunnel.call(port: ENV.fetch("PORT", "3000").to_i)
    end
  end
end
