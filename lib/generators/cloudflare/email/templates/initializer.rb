# frozen_string_literal: true

# Cloudflare Email configuration.
#
# Outbound: ActionMailer delivery method `:cloudflare` is registered automatically.
# Set settings here or per-environment.
#
# Inbound: ActionMailbox ingress is mounted at
#   /rails/action_mailbox/cloudflare/inbound_emails
# Set `config.action_mailbox.ingress = :cloudflare` (the install generator
# does this for development and production by default) and configure cloudflare.ingress_secret
# in your Rails credentials.

Rails.application.configure do
  config.action_mailer.delivery_method = :cloudflare
  config.action_mailer.cloudflare_settings = {
    account_id: Cloudflare::Email::Credentials.account_id,
    api_token:  Cloudflare::Email::Credentials.api_token,
  }
end
