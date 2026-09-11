# Explicit opt-in: require this before Rails initializes, then configure the
# adapter in an initializer. Loading the core gem never mounts this interface.
require "rails/engine"
require "cloudflare-email"
require "cloudflare/email/management/adapter"
require "cloudflare/email/management/configuration"
require "cloudflare/email/management/engine"
