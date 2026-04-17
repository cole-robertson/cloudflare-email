#!/usr/bin/env ruby
# Plain Ruby example — no Rails required.
#
# Usage:
#   CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... ruby examples/plain_ruby.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cloudflare-email"

client = Cloudflare::Email::Client.new(
  account_id: ENV.fetch("CLOUDFLARE_ACCOUNT_ID"),
  api_token:  ENV.fetch("CLOUDFLARE_API_TOKEN"),
)

response = client.send(
  from:    { address: "agent@example.com", name: "Demo Agent" },
  to:      "you@example.com",
  subject: "Hello from cloudflare-email",
  text:    "It works!",
  html:    "<p><strong>It works!</strong></p>",
)

puts "delivered: #{response.delivered.inspect}"
puts "message_id: #{response.message_id}"
