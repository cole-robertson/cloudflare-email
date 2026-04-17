require "cloudflare/email/version"
require "cloudflare/email/error"
require "cloudflare/email/response"
require "cloudflare/email/client"
require "cloudflare/email/secure_reply"
require "cloudflare/email/secure_message_id"

require "cloudflare/email/engine" if defined?(::Rails::Engine)
