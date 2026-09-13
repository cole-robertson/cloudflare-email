require "cloudflare/email/tenancy"
require "mailbox_kit/tenant_job_context"
module Cloudflare
  module Email
    TenantJobContext = MailboxKit::TenantJobContext
  end
end
