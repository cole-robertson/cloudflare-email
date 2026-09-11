namespace :cloudflare do
  namespace :email do
    desc "Run diagnostics against your Cloudflare Email setup"
    task doctor: :environment do
      require "cloudflare/email/doctor"
      exit Cloudflare::Email::Doctor.call
    end

    desc "Send a real test email (both FROM=addr and TO=addr are required)"
    task send_test: :environment do
      require "cloudflare/email/send_test"
      exit Cloudflare::Email::SendTest.call(to: ENV["TO"], from: ENV["FROM"])
    end

    desc "Deploy the Worker via Cloudflare API. URL=https://... sets RAILS_INGRESS_URL; SCRIPT=path overrides the Worker source"
    task deploy_worker: :environment do
      require "cloudflare/email/deploy_worker_task"
      exit Cloudflare::Email::DeployWorkerTask.call(ingress_url: ENV["URL"], script_path: ENV["SCRIPT"])
    end

    desc "Create Cloudflare Email Routing rule: ADDRESS=addr@domain → env-scoped Worker (WORKER=name to override)"
    task provision_route: :environment do
      require "cloudflare/email/provision_route_task"
      exit Cloudflare::Email::ProvisionRouteTask.call(
        address:     ENV["ADDRESS"],
        worker_name: ENV["WORKER"],
      )
    end

    desc "Point a zone-wide catch-all at the env-scoped Worker (DOMAIN=example.com [WORKER=name])"
    task provision_catchall: :environment do
      require "cloudflare/email/provision_catchall_task"
      exit Cloudflare::Email::ProvisionCatchallTask.call(
        domain:      ENV["DOMAIN"],
        worker_name: ENV["WORKER"],
      )
    end

    desc "Run a cloudflared tunnel pointed at this Rails app, update the Worker's RAILS_INGRESS_URL, and tail logs"
    task dev: :environment do
      require "cloudflare/email/dev_tunnel"
      Cloudflare::Email::DevTunnel.call(port: ENV.fetch("PORT", "3000").to_i)
    end

    desc "Process one batch of outbound delivery events using config.x.cloudflare_email.event_handler"
    task consume_events: :environment do
      require "cloudflare/email/consume_events_task"
      settings = Rails.application.config.x.cloudflare_email
      exit Cloudflare::Email::ConsumeEventsTask.call(
        handler: settings.event_handler,
        domains: settings.event_domains,
        batch_size: Integer(ENV.fetch("BATCH_SIZE", "5"), 10),
      )
    end

    desc "Send a prepared durable operation using OPERATION_KEY (no new message is generated)"
    task deliver: :environment do
      require "cloudflare/email/send_job"
      delivery = Cloudflare::Email::SendJob.perform_now(
        Cloudflare::Email::Credentials.account_id, ENV.fetch("OPERATION_KEY"))
      puts "operation=#{delivery.operation_key} state=#{delivery.state}"
    end

    desc "Replay durable outbound receipts for the configured account (optional MESSAGE_ID)"
    task replay_events: :environment do
      require "cloudflare/email/replay_events_job"
      count = Cloudflare::Email::ReplayEventsJob.perform_now(
        Cloudflare::Email::Credentials.account_id, ENV["MESSAGE_ID"])
      puts "Replayed #{count} receipt(s)."
    end

    desc "List prepared or uncertain outbound operations requiring dispatch or operator review"
    task pending_deliveries: :environment do
      require "cloudflare/email/active_record"
      Cloudflare::Email::ActiveRecord::OutboundDelivery.where(
        account_id: Cloudflare::Email::Credentials.account_id,
        state: %w[prepared sending unknown partial]).find_each do |delivery|
        puts "operation=#{delivery.operation_key} state=#{delivery.state} updated_at=#{delivery.updated_at.iso8601}"
      end
    end
  end
end
