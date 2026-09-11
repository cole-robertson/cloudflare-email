/**
 * Cloudflare Email Worker → Rails ActionMailbox ingress.
 *
 * Receives mail via Cloudflare Email Routing, signs the raw RFC822 with
 * HMAC-SHA256 over "v2.{timestamp}.{encoded_envelope}.{raw_body}", and POSTs it to the Rails
 * ingress controller shipped with the cloudflare-email gem.
 * Custom integrations can opt into v3, binding provider metadata into the signature.
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

function validIngressUrl(value) {
  try {
    const url = new URL(value);
    const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    return !url.username && !url.password && !url.hash &&
      (url.protocol === "https:" || (url.protocol === "http:" && loopback));
  } catch { return false; }
}

async function readBounded(stream, limit) {
  const reader = stream.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) {
        await reader.cancel();
        throw new Error("message exceeds size limit");
      }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const raw = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { raw.set(chunk, offset); offset += chunk.byteLength; }
  return raw;
}

function plainObject(value) {
  return value !== null && typeof value === "object" &&
    [Object.prototype, null].includes(Object.getPrototypeOf(value));
}

function validateJson(value, depth = 1) {
  if (typeof value === "string") {
    if (/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) {
      throw new TypeError("metadata strings must be valid Unicode");
    }
    return;
  }
  if (value === null || typeof value === "boolean" ||
      (typeof value === "number" && Number.isFinite(value))) return;
  if (depth > 8 || (!Array.isArray(value) && !plainObject(value))) {
    throw new TypeError("metadata must contain JSON values with at most 8 container levels");
  }
  for (const [key, item] of Object.entries(value)) {
    validateJson(key, depth + 1);
    validateJson(item, depth + 1);
  }
}

function base64url(value) {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function encodeMetadata(metadata) {
  if (!plainObject(metadata) || Object.keys(metadata).sort().join(",") !== "data,source" ||
      typeof metadata.source !== "string" || !/^[a-z][a-z0-9_.-]{0,127}$/.test(metadata.source) ||
      !plainObject(metadata.data)) throw new TypeError("invalid provider metadata");
  validateJson(metadata);
  const encoded = base64url(JSON.stringify({ source: metadata.source, data: metadata.data }));
  if (encoded.length > 16384) throw new TypeError("encoded metadata exceeds 16384 characters");
  return encoded;
}

// Custom transports own their body limits, destination, retries and error handling.
// Metadata is a host assertion; never derive trusted facts from MIME headers.
export async function signedEmailHeaders({ secret, raw, from, to, metadata, timestamp = Math.floor(Date.now() / 1000).toString() }) {
  if (typeof secret !== "string" || secret.length === 0) throw new TypeError("missing ingress secret");
  if (!(raw instanceof Uint8Array)) throw new TypeError("raw must be a Uint8Array");
  if (!validAddress(from, true) || !validAddress(to)) throw new TypeError("invalid SMTP envelope");
  const ts = String(timestamp);
  if (!/^[0-9]{1,12}$/.test(ts)) throw new TypeError("invalid timestamp");
  const envelope = base64url(JSON.stringify({ from, to }));
  const encodedMetadata = metadata === undefined ? undefined : encodeMetadata(metadata);
  const version = encodedMetadata === undefined ? "2" : "3";
  const prefix = new TextEncoder().encode(`v${version}.${ts}.${envelope}.${encodedMetadata === undefined ? "" : `${encodedMetadata}.`}`);
  const signedPayload = new Uint8Array(prefix.length + raw.length);
  signedPayload.set(prefix);
  signedPayload.set(raw, prefix.length);
  const headers = {
    "Content-Type": "message/rfc822",
    "X-CF-Email-Timestamp": ts,
    "X-CF-Email-Signature": await sign(secret, signedPayload),
    "X-CF-Email-Signature-Version": version,
    "X-CF-Email-Envelope": envelope,
  };
  if (encodedMetadata !== undefined) headers["X-CF-Email-Metadata"] = encodedMetadata;
  return headers;
}

export async function forwardEmail(message, env, { metadata } = {}) {
    if (!env.RAILS_INGRESS_URL || !env.INGRESS_SECRET) {
      message.setReject("worker missing RAILS_INGRESS_URL or INGRESS_SECRET");
      return;
    }

    if (!validIngressUrl(env.RAILS_INGRESS_URL)) {
      message.setReject("worker requires an HTTPS ingress URL (HTTP allowed only for loopback)");
      return;
    }
    const limit = env.MAX_EMAIL_BYTES === undefined ? 25 * 1024 * 1024 : Number(env.MAX_EMAIL_BYTES);
    if (!Number.isSafeInteger(limit) || limit <= 0) {
      message.setReject("worker MAX_EMAIL_BYTES must be a positive integer");
      return;
    }
    if (message.rawSize > limit) {
      message.setReject("message exceeds size limit");
      return;
    }

    if (!validAddress(message.from, true) || !validAddress(message.to)) {
      message.setReject("worker received invalid SMTP envelope");
      return;
    }
    let raw;
    try {
      raw = await readBounded(message.raw, limit);
    } catch {
      message.setReject("message exceeds size limit or could not be read");
      return;
    }
    let headers;
    try {
      headers = await signedEmailHeaders({ secret: env.INGRESS_SECRET, raw, from: message.from, to: message.to, metadata });
    } catch {
      message.setReject("worker could not sign envelope or provider metadata");
      return;
    }

    let res;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      res = await fetch(env.RAILS_INGRESS_URL, {
        method: "POST",
        headers,
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
}

export default {
  email(message, env) { return forwardEmail(message, env); },
};
