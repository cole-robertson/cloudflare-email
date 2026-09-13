require "cloudflare/email/tenancy"
require "mailbox_kit/active_record/base"
module Cloudflare
  module Email
    module ActiveRecord
      Base = MailboxKit::ActiveRecord::Base
      TenantConnectionUnavailable = MailboxKit::ActiveRecord::TenantConnectionUnavailable
    end
  end
end
