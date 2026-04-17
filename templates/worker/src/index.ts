/**
 * Cloudflare Email Worker → Rails ActionMailbox ingress.
 *
 * Receives mail via Cloudflare Email Routing, signs the raw RFC822 with
 * HMAC-SHA256 over "{timestamp}.{raw_body}", and POSTs it to the Rails
 * ingress controller shipped with the cloudflare-email gem.
 *
 * Configure via `wrangler secret put`:
 *   RAILS_INGRESS_URL   e.g. https://your-app.example.com/rails/action_mailbox/cloudflare/inbound_emails
 *   INGRESS_SECRET      shared secret (same as cloudflare.ingress_secret in Rails credentials)
 */

export interface Env {
  RAILS_INGRESS_URL: string;
  INGRESS_SECRET: string;
}

interface ForwardableEmailMessage {
  readonly from: string;
  readonly to: string;
  readonly raw: ReadableStream<Uint8Array>;
  readonly rawSize: number;
  setReject(reason: string): void;
}

function toHex(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}

async function sign(secret: string, data: Uint8Array): Promise<string> {
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

export default {
  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    if (!env.RAILS_INGRESS_URL || !env.INGRESS_SECRET) {
      message.setReject("worker missing RAILS_INGRESS_URL or INGRESS_SECRET");
      return;
    }

    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());
    const ts = Math.floor(Date.now() / 1000).toString();

    const tsBytes = new TextEncoder().encode(`${ts}.`);
    const signedPayload = new Uint8Array(tsBytes.length + raw.length);
    signedPayload.set(tsBytes, 0);
    signedPayload.set(raw, tsBytes.length);

    const signature = await sign(env.INGRESS_SECRET, signedPayload);

    let res: Response;
    try {
      res = await fetch(env.RAILS_INGRESS_URL, {
        method: "POST",
        headers: {
          "Content-Type": "message/rfc822",
          "X-CF-Email-Timestamp": ts,
          "X-CF-Email-Signature": signature,
        },
        body: raw,
      });
    } catch (err) {
      message.setReject(`upstream fetch failed: ${(err as Error).message}`);
      return;
    }

    if (!res.ok) {
      message.setReject(`upstream returned ${res.status}`);
    }
  },
};
