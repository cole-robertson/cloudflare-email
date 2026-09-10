/**
 * Cloudflare Email Worker → Rails ActionMailbox ingress.
 *
 * Receives mail via Cloudflare Email Routing, signs the raw RFC822 with
 * HMAC-SHA256 over "v2.{timestamp}.{encoded_envelope}.{raw_body}", and POSTs it to the Rails
 * ingress controller shipped with the cloudflare-email gem.
 *
 * Required environment variables (set via `wrangler secret put` OR the
 * `cloudflare:email:deploy_worker` rake task shipped with this gem):
 *
 *   RAILS_INGRESS_URL   e.g. https://your-app.example.com/rails/action_mailbox/cloudflare/inbound_emails
 *   INGRESS_SECRET      shared secret (same as cloudflare.ingress_secret in Rails credentials)
 */

function toHex(buf) {
  const bytes = new Uint8Array(buf);
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

async function sign(secret, data) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, data);
  return toHex(sig);
}

function validAddress(address, allowEmpty = false) {
  if (typeof address !== "string" || address.length > 254 || /[^\x21-\x7E]/.test(address)) return false;
  if (allowEmpty && address === "") return true;
  const parts = address.split("@");
  if (parts.length !== 2) return false;
  const [local, domain] = parts;
  return local.length <= 64 && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(local) &&
    !local.startsWith(".") && !local.endsWith(".") && !local.includes("..") &&
    domain.split(".").every(label => /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(label));
}

export default {
  async email(message, env) {
    if (!env.RAILS_INGRESS_URL || !env.INGRESS_SECRET) {
      message.setReject("worker missing RAILS_INGRESS_URL or INGRESS_SECRET");
      return;
    }

    if (!validAddress(message.from, true) || !validAddress(message.to)) {
      message.setReject("worker received invalid SMTP envelope");
      return;
    }
    // Routing metadata comes from the SMTP envelope, never from MIME headers.
    const envelope = btoa(JSON.stringify({ from: message.from, to: message.to }))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());
    const ts = Math.floor(Date.now() / 1000).toString();

    const tsBytes = new TextEncoder().encode(`v2.${ts}.${envelope}.`);
    const signedPayload = new Uint8Array(tsBytes.length + raw.length);
    signedPayload.set(tsBytes, 0);
    signedPayload.set(raw, tsBytes.length);

    const signature = await sign(env.INGRESS_SECRET, signedPayload);

    let res;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      res = await fetch(env.RAILS_INGRESS_URL, {
        method: "POST",
        headers: {
          "Content-Type": "message/rfc822",
          "X-CF-Email-Timestamp": ts,
          "X-CF-Email-Signature": signature,
          "X-CF-Email-Signature-Version": "2",
          "X-CF-Email-Envelope": envelope,
        },
        body: raw,
        signal: controller.signal,
        // Workers supports follow/manual; non-2xx handling below rejects redirects.
        redirect: "manual",
      });
    } catch (err) {
      message.setReject(controller.signal.aborted ? "upstream fetch timed out" : "upstream fetch failed");
      return;
    } finally {
      clearTimeout(timeout);
    }

    if (!res.ok) {
      message.setReject(`upstream returned ${res.status}`);
    }
  },
};
