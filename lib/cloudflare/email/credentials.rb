module Cloudflare
  module Email
    # Unified credential lookup.
    #
    # Precedence:
    #   1. Rails.application.credentials.dig(:cloudflare, key) — encrypted credentials.yml.enc
    #      (respects per-environment files: config/credentials/{env}.yml.enc when present)
    #   2. ENV["CLOUDFLARE_#{KEY}"] — env vars, including anything dotenv or foreman loaded from .env
    #
    # Supported keys:
    #   account_id       — Cloudflare account ID
    #   api_token        — runtime token used by the delivery method (needs Email Sending: Send)
    #   management_token — higher-privilege token used by deploy/provision rake tasks
    #                      (needs Workers Scripts: Edit, Zone: Read, Email Routing: Edit).
    #                      Falls back to api_token if not set.
    #   ingress_secret   — HMAC shared secret between Worker and Rails ingress
    module Credentials
      class << self
        def account_id
          fetch(:account_id)
        end

        def api_token
          fetch(:api_token)
        end

        # For deploy_worker, provision_route, and dev tasks. Prefer a
        # dedicated higher-privilege token if the user has split them;
        # otherwise reuse api_token (most single-token setups).
        def management_token
          token = fetch(:management_token)
          token.empty? ? api_token : token
        end

        def ingress_secret
          fetch(:ingress_secret)
        end

        # True if the user has set a separate management token.
        def split_tokens?
          !fetch(:management_token).empty?
        end

        def fetch(key)
          from_rails = rails_credentials_dig(key)
          return from_rails unless from_rails.empty?
          ENV["CLOUDFLARE_#{key.to_s.upcase}"].to_s
        end

        def rails_credentials_dig(key)
          return "" unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.credentials.dig(:cloudflare, key).to_s
        rescue StandardError
          ""
        end
      end
    end
  end
end
