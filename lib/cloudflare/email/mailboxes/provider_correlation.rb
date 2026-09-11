module Cloudflare
  module Email
    module Mailboxes
      # Shared routing evidence, never inferred from a sender or event domain.
      class ProviderCorrelation < Mailboxes.directory_base
        self.table_name = "cloudflare_email_provider_correlations"
        attr_readonly :account_id, :message_id, :recipient, :tenant_key, :outbound_delivery_id
      end
    end
  end
end
