/**
 * Cloudflare Email Worker → Rails ActionMailbox ingress.
 *
 * Receives mail via Cloudflare Email Routing, signs the raw RFC822 with
 * HMAC-SHA256 over "v2.{timestamp}.{encoded_envelope}.{raw_body}", and POSTs it to the Rails
 * ingress controller shipped with the cloudflare-email gem.
 * Custom integrations can opt into v3, binding provider metadata into the signature.
 * The default handler commits to INBOUND_EMAIL_STORE (R2), then queues delivery
 * through INBOUND_EMAIL_QUEUE. Keep a minute cron for recovery after queue loss.
 * INBOUND_DELIVERY_MODE=direct explicitly selects the single-attempt fallback.
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

// Generic relays preserve host address semantics; signed gem ingress is stricter.
function validTransportEnvelope(from, to) {
  return [from, to].every(value => typeof value === "string" && value.length <= 254 &&
    !/[\x00-\x1f\x7f]/.test(value)) && to.length > 0;
}

async function readBounded(stream, limit) {
  const reader = stream.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array)) throw new TypeError("invalid message chunk");
      size += value.byteLength;
      if (size > limit) {
        const error = new Error("message exceeds size limit");
        error.code = "EMAIL_TOO_LARGE";
        throw error;
      }
      chunks.push(value);
    }
  } catch (error) {
    void reader.cancel().catch(() => {});
    throw error;
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

// Stores only transport metadata. The key and retention policy belong to the host.
export async function archiveEmail({ bucket, key, raw, from, to }) {
  if (!bucket || typeof bucket.put !== "function" || typeof key !== "string" ||
      key.length === 0 || new TextEncoder().encode(key).length > 1024 || /[\x00-\x1f\x7f]/.test(key) ||
      !(raw instanceof Uint8Array) || !validTransportEnvelope(from, to)) {
    throw new TypeError("invalid email archive arguments");
  }
  await bucket.put(key, raw, {
    httpMetadata: { contentType: "message/rfc822" },
    customMetadata: { from: from.replace(/[^\x20-\x7e]/g, "?"),
      to: to.replace(/[^\x20-\x7e]/g, "?"), size: String(raw.byteLength) },
  });
  return { key };
}

async function postEmail(url, headers, raw, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetch(url, { method: "POST", headers, body: raw,
      redirect: "manual", signal: controller.signal });
  } catch {
    return { reason: controller.signal.aborted ? "timeout" : "fetch_failed" };
  } finally { clearTimeout(timeout); }
  // Never read or return backend error bodies; they can contain mail or secrets.
  try { void response.body?.cancel().catch(() => {}); } catch { /* cancellation is best effort */ }
  return { reason: response.ok ? "delivered" : "http_status", httpStatus: response.status };
}

async function archiveWithin(saveArchive, args, timeoutMs) {
  let timeout;
  try {
    return await Promise.race([
      Promise.resolve().then(() => saveArchive(args)),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error("archive timed out")), timeoutMs);
      }),
    ]);
  } finally { clearTimeout(timeout); }
}

// A host-controlled relay: no SMTP rejection, sender policy, fallback or retries.
// Callback exceptions are deliberately reduced to fixed, non-sensitive reasons.
export async function relayEmail(message, options = {}) {
  let archiveFailed = false;
  const result = (status, reason, httpStatus) => ({ status, reason, archiveFailed,
    ...(httpStatus === undefined ? {} : { httpStatus }) });
  if (!options || typeof options !== "object") return result("failed", "invalid_options");
  const { maxEmailBytes = 25 * 1024 * 1024, timeoutMs = 15_000, archiveTimeoutMs = 10_000,
    resolveBackend, headers: buildHeaders, archive: saveArchive, accepts } = options;
  if (!Number.isSafeInteger(maxEmailBytes) || maxEmailBytes <= 0 ||
      !Number.isSafeInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 2_147_483_647 ||
      !Number.isSafeInteger(archiveTimeoutMs) || archiveTimeoutMs <= 0 || archiveTimeoutMs > 2_147_483_647 ||
      typeof resolveBackend !== "function" || typeof buildHeaders !== "function" ||
      (saveArchive !== undefined && typeof saveArchive !== "function") ||
      (accepts !== undefined && typeof accepts !== "function")) return result("failed", "invalid_options");
  if (!message || !validTransportEnvelope(message.from, message.to)) {
    return result("rejected", "invalid_envelope");
  }
  const { from, to } = message;
  if (message.rawSize > maxEmailBytes) return result("rejected", "too_large");
  let raw;
  try { raw = await readBounded(message.raw, maxEmailBytes); }
  catch (error) {
    return error?.code === "EMAIL_TOO_LARGE" ? result("rejected", "too_large") : result("failed", "unreadable");
  }
  let archive;
  if (saveArchive) {
    try { archive = await archiveWithin(saveArchive, { raw, from, to }, archiveTimeoutMs); }
    catch { archiveFailed = true; }
  }
  if (accepts) {
    try {
      if (await accepts({ from, to }) !== true) return result("rejected", "not_accepted");
    } catch { return result("failed", "acceptance_failed"); }
  }
  let backend;
  let url;
  try {
    backend = await resolveBackend({ from, to });
    url = backend?.url;
  }
  catch { return result("failed", "backend_failed"); }
  if (typeof url !== "string" || !validIngressUrl(url)) {
    return result("failed", "invalid_backend");
  }
  let headers;
  try {
    const supplied = await buildHeaders({ raw, from, to, backend, archive });
    if (!supplied || typeof supplied !== "object") return result("failed", "headers_failed");
    headers = new Headers(supplied);
  } catch { return result("failed", "headers_failed"); }
  const delivery = await postEmail(url, headers, raw, timeoutMs);
  return result(delivery.reason === "delivered" ? "delivered" : "failed", delivery.reason, delivery.httpStatus);
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

    const delivery = await postEmail(env.RAILS_INGRESS_URL, headers, raw, 15_000);
    if (delivery.reason === "timeout") message.setReject("upstream fetch timed out");
    else if (delivery.reason === "fetch_failed") message.setReject("upstream fetch failed");
    else if (delivery.reason === "http_status") message.setReject(`upstream returned ${delivery.httpStatus}`);
}

const PENDING_PREFIX = "cloudflare-email/pending/";
const CURSOR_KEY = "cloudflare-email/state/sweep";

function durableConfig(env) {
  if (!env.INBOUND_EMAIL_STORE || !env.INBOUND_EMAIL_QUEUE ||
      !validIngressUrl(env.RAILS_INGRESS_URL) || !env.INGRESS_SECRET) {
    throw new Error("durable inbound configuration invalid");
  }
  const limit = Number(env.MAX_EMAIL_BYTES ?? 25 * 1024 * 1024);
  if (!Number.isSafeInteger(limit) || limit <= 0) throw new Error("invalid inbound size limit");
  return limit;
}

function durableLog(reason, key, httpStatus) {
  console.warn(JSON.stringify({ component: "cloudflare_email_inbound", reason, key,
    ...(httpStatus === undefined ? {} : { httpStatus }) }));
}

// One atomic R2 object holds both the original bytes and stable signed context.
// Queue messages are disposable wakeups; pending objects are the source of truth.
export async function retainEmail(message, env, { metadata, archive } = {}) {
  const limit = durableConfig(env);
  if (archive !== undefined && typeof archive !== "function") throw new Error("invalid inbound archive callback");
  if (!validAddress(message.from, true) || !validAddress(message.to)) {
    message.setReject("worker received invalid SMTP envelope");
    return;
  }
  if (metadata !== undefined) encodeMetadata(metadata);
  let raw;
  try {
    if (message.rawSize > limit) {
      message.setReject("message exceeds size limit");
      return;
    }
    raw = await readBounded(message.raw, limit);
  } catch (error) {
    if (error?.code !== "EMAIL_TOO_LARGE") throw new Error("inbound message read failed");
    message.setReject("message exceeds size limit");
    return;
  }
  const key = `${PENDING_PREFIX}${crypto.randomUUID()}`;
  const context = new TextEncoder().encode(JSON.stringify({ version: 1,
    from: message.from, to: message.to, metadata, receivedAt: new Date().toISOString() }));
  const stored = new Uint8Array(4 + context.length + raw.length);
  new DataView(stored.buffer).setUint32(0, context.length);
  stored.set(context, 4);
  stored.set(raw, 4 + context.length);
  try {
    // Deliberately awaited, never waitUntil or a best-effort archive.
    await env.INBOUND_EMAIL_STORE.put(key, stored,
      { httpMetadata: { contentType: "application/octet-stream" } });
  } catch {
    durableLog("storage_failed", key);
    throw new Error("inbound durable storage unavailable");
  }
  // A secondary archive receives the public raw/context contract, never the
  // private storage frame. Its failure cannot undo the primary durable write.
  if (archive) {
    try { await archiveWithin(archive, { raw, from: message.from, to: message.to, key }, 10_000); }
    catch { durableLog("archive_failed_retained", key); }
  }
  try { await env.INBOUND_EMAIL_QUEUE.send({ version: 1, key }); }
  catch { durableLog("enqueue_failed_retained", key); }
  return { key };
}

export async function deliverRetainedEmail(key, env) {
  const limit = durableConfig(env);
  if (typeof key !== "string" || !/^cloudflare-email\/pending\/[0-9a-f-]{36}$/.test(key)) {
    throw new Error("invalid retained email key");
  }
  const bucket = env.INBOUND_EMAIL_STORE;
  // A previous successful attempt may have deleted the pending object already.
  const object = await bucket.get(key);
  if (!object) return;
  if (object.size > limit + 32772) throw new Error("retained email exceeds configured size");
  const stored = await readBounded(object.body, limit + 32772);
  if (stored.length < 4) throw new Error("invalid retained email");
  const length = new DataView(stored.buffer, stored.byteOffset).getUint32(0);
  if (length > 32768 || length > stored.length - 4) throw new Error("invalid retained email context");
  const context = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(stored.subarray(4, 4 + length)));
  const raw = stored.subarray(4 + length);
  if (context.version !== 1 || raw.length > limit) throw new Error("invalid retained email version or size");
  const headers = await signedEmailHeaders({ secret: env.INGRESS_SECRET, raw,
    from: context.from, to: context.to, metadata: context.metadata });
  const result = await postEmail(env.RAILS_INGRESS_URL, headers, raw, 15_000);
  if (result.reason !== "delivered") {
    durableLog(result.reason, key, result.httpStatus);
    throw new Error("inbound handoff incomplete");
  }
  // Delete only after Rails durable acceptance. A lost response or failed delete
  // leaves the identical object available for idempotent replay, never rewrites it.
  await bucket.delete(key);
}

export async function consumeRetainedEmails(batch, env) {
  for (const message of batch.messages) {
    try {
      if (message.body?.version !== 1) throw new Error("invalid queue pointer");
      await deliverRetainedEmail(message.body.key, env);
      message.ack();
    } catch {
      durableLog("queue_retry_retained", typeof message.body?.key === "string" &&
        /^cloudflare-email\/pending\/[0-9a-f-]{36}$/.test(message.body.key) ? message.body.key : undefined);
      message.retry({ delaySeconds: 300 });
    }
  }
}

export async function sweepRetainedEmails(env) {
  durableConfig(env);
  const bucket = env.INBOUND_EMAIL_STORE;
  const state = await bucket.get(CURSOR_KEY);
  const cursor = state ? await state.text() : undefined;
  // Five attempts fit comfortably within the scheduled handler's wall-time cap.
  // Advance even over poison entries; the next traversal retries them again.
  const page = await bucket.list({ prefix: PENDING_PREFIX, limit: 5,
    ...(cursor ? { cursor } : {}) });
  for (const object of page.objects) {
    try { await deliverRetainedEmail(object.key, env); }
    catch { durableLog("sweep_retry_retained", object.key); }
  }
  if (page.truncated) await bucket.put(CURSOR_KEY, page.cursor);
  else await bucket.delete(CURSOR_KEY);
}

export default {
  email(message, env) {
    const mode = env.INBOUND_DELIVERY_MODE ?? "durable";
    if (mode === "direct") return forwardEmail(message, env);
    if (mode !== "durable") throw new Error("INBOUND_DELIVERY_MODE must be durable or direct");
    return retainEmail(message, env);
  },
  queue(batch, env) { return consumeRetainedEmails(batch, env); },
  scheduled(_event, env, ctx) {
    // Keep draining retained mail during a direct-mode rollback. A direct-only
    // deployment has no schedule or storage; partial durable config must fail.
    if (env.INBOUND_DELIVERY_MODE !== "direct" || env.INBOUND_EMAIL_STORE || env.INBOUND_EMAIL_QUEUE) {
      ctx.waitUntil(sweepRetainedEmails(env));
    }
  },
};
