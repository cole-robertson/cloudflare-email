require "rails/generators/base"
require "securerandom"

module Cloudflare
  module Email
    module Generators
      class InstallGenerator < ::Rails::Generators::Base
        namespace "cloudflare:email:install"

        source_root File.expand_path("templates", __dir__)

        class_option :inbound, type: :boolean, default: true,
                     desc: "Set up ActionMailbox ingress + Cloudflare Worker template for inbound mail"

        class_option :worker_dir, type: :string, default: "cloudflare-worker",
                     desc: "Directory to copy the Cloudflare Worker template into"

        class_option :all_envs, type: :boolean, default: false,
                     desc: "Also configure action_mailbox.ingress in development.rb and test.rb (not just production.rb)"

        class_option :deploy_worker, type: :boolean, default: nil,
                     desc: "Deploy the Worker via wrangler after setup (nil = interactive prompt)"

        class_option :scaffold_mailbox, type: :boolean, default: nil,
                     desc: "Scaffold MainMailbox + catch-all route so inbound has somewhere to land (nil = interactive prompt)"

        def create_initializer
          template "initializer.rb", "config/initializers/cloudflare_email.rb"
        end

        def ensure_action_mailbox_installed
          return unless options[:inbound]
          return if File.exist?("app/mailboxes/application_mailbox.rb")

          say ""
          if yes?("ActionMailbox isn't installed yet. Run `bin/rails action_mailbox:install` now? [Y/n]", :green)
            rails_command "action_mailbox:install", inline: true
            rails_command "db:migrate",             inline: true
          else
            say "  Skipping — run `bin/rails action_mailbox:install` manually before inbound will work.", :yellow
          end
        end

        def maybe_scaffold_mailbox
          return unless options[:inbound]
          return unless File.exist?("app/mailboxes/application_mailbox.rb")

          if File.exist?("app/mailboxes/main_mailbox.rb")
            say "  app/mailboxes/main_mailbox.rb already exists — skipping.", :cyan
            return
          end

          if active_route?("app/mailboxes/application_mailbox.rb")
            say "  ApplicationMailbox already has routes — skipping MainMailbox scaffold.", :cyan
            return
          end

          should_scaffold = options[:scaffold_mailbox]
          if should_scaffold.nil?
            should_scaffold = yes?(
              "Scaffold a default MainMailbox + catch-all route so inbound has somewhere to land? [Y/n]",
              :green,
            )
          end
          return unless should_scaffold

          template "main_mailbox.rb", "app/mailboxes/main_mailbox.rb"

          inject_into_class "app/mailboxes/application_mailbox.rb", "ApplicationMailbox" do
            "  routing :all => :main\n"
          end
        end

        def configure_action_mailbox_ingress
          return unless options[:inbound]

          envs = ["production"]
          envs += ["development", "test"] if options[:all_envs]

          envs.each do |env|
            file = "config/environments/#{env}.rb"
            next unless File.exist?(file)
            next if File.read(file).include?("action_mailbox.ingress = :cloudflare")

            inject_into_file file,
              "  config.action_mailbox.ingress = :cloudflare\n",
              after: /Rails\.application\.configure do\n/
          end
        end

        def copy_worker_template
          return unless options[:inbound]

          worker_src = File.expand_path("../../../../templates/worker", __dir__)
          directory worker_src, options[:worker_dir]
        end

        def maybe_deploy_worker
          return unless options[:inbound]

          should_deploy = options[:deploy_worker]
          if should_deploy.nil?
            say ""
            say "  The Worker can be deployed via the Cloudflare API (pure Ruby, no wrangler/Node)"
            say "  once you've set cloudflare.account_id and cloudflare.api_token in Rails credentials."
            say "  Run `bin/rails cloudflare:email:deploy_worker URL=https://yourapp.com#{ingress_path}`"
            say "  after `bin/rails credentials:edit`."
            say ""
            say "  Alternatively, deploy now via wrangler if it's installed locally." if wrangler_installed?
          end

          if should_deploy && wrangler_installed?
            wrangler_deploy
          end
        end

        def wrangler_deploy
          @ingress_secret = SecureRandom.hex(32)

          inside options[:worker_dir] do
            run "npm install --legacy-peer-deps", abort_on_failure: true

            ingress_url = ask("Rails ingress URL? (e.g. https://yourapp.com#{ingress_path})")
            if ingress_url.to_s.strip.empty?
              say "  Skipping Worker deploy — no URL supplied. Re-run `wrangler deploy` manually when ready.", :yellow
              return
            end

            run_with_stdin("wrangler secret put RAILS_INGRESS_URL", ingress_url.strip)
            run_with_stdin("wrangler secret put INGRESS_SECRET",    @ingress_secret)
            run "wrangler deploy", abort_on_failure: false
          end

          @worker_deployed = true
        end

        def print_post_install
          @ingress_secret ||= SecureRandom.hex(32) if options[:inbound]

          say ""
          say "  cloudflare-email installed.", :green
          say ""
          say "  Next steps:"
          say ""
          say "  1. Add credentials:"
          say "       bin/rails credentials:edit"
          say "     cloudflare:"
          say "       account_id: <your-account-id>"
          say "       api_token:  <your-api-token>"
          if options[:inbound]
            say "       ingress_secret: #{@ingress_secret}"
          end
          say ""
          say "  2. Verify your setup:"
          say "       bin/rails cloudflare:email:doctor"
          say ""
          say "  3. Send a test email:"
          say "       TO=you@example.com bin/rails cloudflare:email:send_test"
          say ""

          if options[:inbound] && !@worker_deployed
            say "  4. Deploy the Worker (pick one):"
            say "       # Pure Ruby (recommended — no wrangler/Node required):"
            say "       bin/rails cloudflare:email:deploy_worker URL=https://yourapp.com#{ingress_path}"
            say ""
            say "       # Or via wrangler if you have it installed:"
            say "       cd #{options[:worker_dir]}"
            say "       npm install --legacy-peer-deps"
            say "       wrangler secret put INGRESS_SECRET     # paste #{@ingress_secret[0, 8]}..."
            say "       wrangler secret put RAILS_INGRESS_URL  # https://yourapp.com#{ingress_path}"
            say "       wrangler deploy"
            say ""
          end

          if options[:inbound]
            say "  5. For local dev (tunnels cloudflared to your Worker):"
            say "       bin/rails cloudflare:email:dev"
            say ""
            say "  6. In the Cloudflare dashboard:"
            say "       Email Routing -> Routes -> Send to a Worker -> #{worker_name}"
            say ""
            say "  Dashboard deep-links:"
            say "    API tokens:       https://dash.cloudflare.com/profile/api-tokens"
            say "    Sending domains:  https://dash.cloudflare.com/?to=/:account/email/sending"
            say "    Email routing:    https://dash.cloudflare.com/?to=/:account/email/routing"
            say ""
            say "  Rotation: to rotate the ingress secret, update cloudflare.ingress_secret"
            say "  in Rails credentials AND re-run `wrangler secret put INGRESS_SECRET` in"
            say "  #{options[:worker_dir]}/ with the new value, then redeploy the Worker."
            say ""
            say "  Dev/test: by default only production.rb is wired to :cloudflare ingress."
            say "  Re-run with --all-envs to also configure development.rb and test.rb."
          end
          say ""
        end

        private

        # True if ApplicationMailbox contains any uncommented `routing` call.
        def active_route?(file)
          return false unless File.exist?(file)
          File.readlines(file).any? { |line| line =~ /^\s*routing\s/ }
        end

        def wrangler_installed?
          system("command -v wrangler >/dev/null 2>&1")
        end

        def ingress_path
          "/rails/action_mailbox/cloudflare/inbound_emails"
        end

        def worker_name
          "cloudflare-email-ingress"
        end

        def run_with_stdin(cmd, input)
          require "open3"
          out, err, status = Open3.capture3(cmd, stdin_data: input + "\n")
          unless status.success?
            say "  #{cmd} failed: #{err.empty? ? out : err}", :red
          end
        end
      end
    end
  end
end
