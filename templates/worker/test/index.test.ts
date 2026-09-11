import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import worker, { forwardEmail, signedEmailHeaders } from "../src/index.js";

// Minimal fake EmailMessage implementing the surface the Worker uses.
function makeMessage(raw: string) {
  const rawBytes = new TextEncoder().encode(raw);
  const rejects: string[] = [];
  return {
    message: {
      from: "sender@external.test",
      to:   "inbox@trial.test",
      raw:  new ReadableStream({
        start(c) { c.enqueue(rawBytes); c.close(); },
      }),
      rawSize: rawBytes.byteLength,
      setReject(reason: string) { rejects.push(reason); },
    },
    rejects,
  };
}

async function verifyHmac(secret: string, ts: string, envelope: string, body: ArrayBuffer, hex: string) {
  const enc = new TextEncoder();
  const prefix = enc.encode(`v2.${ts}.${envelope}.`);
  const signed = new Uint8Array(prefix.length + body.byteLength);
  signed.set(prefix, 0);
  signed.set(new Uint8Array(body), prefix.length);

  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );

  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  }

  return crypto.subtle.verify("HMAC", key, bytes, signed);
}

describe("cloudflare-email Worker", () => {
  const RAW = "From: a@b.com\r\nTo: c@d.com\r\nSubject: hi\r\n\r\nBody line.\r\n";
  const SECRET = "worker-test-secret-abc123";
  const URL_ = "https://rails.test/rails/action_mailbox/cloudflare/inbound_emails";

  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn(async () => new Response("", { status: 200 }));
    vi.stubGlobal("fetch", fetchSpy);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("POSTs raw MIME with HMAC signature and timestamp", async () => {
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET };
    const { message } = makeMessage(RAW);

    await worker.email(message as any, env);

    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, opts] = fetchSpy.mock.calls[0];
    expect(url).toBe(URL_);
    expect(opts.method).toBe("POST");
    expect(opts.headers["Content-Type"]).toBe("message/rfc822");
    const ts = opts.headers["X-CF-Email-Timestamp"];
    const sig = opts.headers["X-CF-Email-Signature"];
    const envelope = opts.headers["X-CF-Email-Envelope"];
    expect(opts.headers["X-CF-Email-Signature-Version"]).toBe("2");
    expect(opts.headers["X-CF-Email-Metadata"]).toBeUndefined();
    expect(JSON.parse(atob(envelope.replace(/-/g, "+").replace(/_/g, "/")))).toEqual({
      from: "sender@external.test", to: "inbox@trial.test",
    });
    expect(ts).toMatch(/^\d+$/);
    expect(sig).toMatch(/^[0-9a-f]{64}$/);

    // Body bytes match the input.
    const sentBytes = opts.body as Uint8Array;
    expect(new TextDecoder().decode(sentBytes)).toBe(RAW);

    // And the signature verifies against the input.
    const ok = await verifyHmac(SECRET, ts, envelope, sentBytes.buffer, sig);
    expect(ok).toBe(true);
  });

  it.each(["http://rails.test/inbound", "https://user:password@rails.test/inbound", "https://rails.test/inbound#fragment", "invalid"])(
    "rejects invalid ingress URL %j before reading mail", async (url) => {
      const { message, rejects } = makeMessage(RAW);
      await worker.email(message as any, { RAILS_INGRESS_URL: url, INGRESS_SECRET: SECRET });
      expect(rejects).toHaveLength(1);
      expect(fetchSpy).not.toHaveBeenCalled();
      expect(message.raw.locked).toBe(false);
    },
  );

  it("allows loopback HTTP for local verification", async () => {
    const { message, rejects } = makeMessage(RAW);
    await worker.email(message as any, { RAILS_INGRESS_URL: "http://127.0.0.1:3000/inbound", INGRESS_SECRET: SECRET });
    expect(rejects).toEqual([]);
    expect(fetchSpy).toHaveBeenCalledOnce();
  });

  it("accepts mail at the configured size boundary", async () => {
    const { message, rejects } = makeMessage(RAW);
    await worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET, MAX_EMAIL_BYTES: String(message.rawSize) });
    expect(rejects).toEqual([]);
    expect(fetchSpy).toHaveBeenCalledOnce();
  });

  it.each([true, false])("enforces size limit with accurate rawSize=%j", async (accurate) => {
    const { message, rejects } = makeMessage(RAW);
    if (!accurate) message.rawSize = 0;
    await worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET, MAX_EMAIL_BYTES: "16" });
    expect(rejects).toHaveLength(1);
    expect(rejects[0]).toMatch(/size limit/);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("rejects invalid size configuration", async () => {
    const { message, rejects } = makeMessage(RAW);
    await worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET, MAX_EMAIL_BYTES: "0" });
    expect(rejects).toHaveLength(1);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("rejects the message when upstream returns non-2xx", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("server error", { status: 503 }));
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET };
    const { message, rejects } = makeMessage(RAW);

    await worker.email(message as any, env);

    expect(rejects).toEqual(["upstream returned 503"]);
  });

  it("authenticates SMTP recipients independently of sender-controlled To headers", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1_750_000_000_000);
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET };
    await worker.email(makeMessage(RAW).message as any, env);
    const other = makeMessage(RAW);
    other.message.to = "bcc@trial.test";
    await worker.email(other.message as any, env);
    const first = fetchSpy.mock.calls[0][1];
    const second = fetchSpy.mock.calls[1][1];
    expect(second.body).toEqual(first.body);
    expect(second.headers["X-CF-Email-Signature"]).not.toBe(first.headers["X-CF-Email-Signature"]);
    expect(await verifyHmac(SECRET, first.headers["X-CF-Email-Timestamp"], second.headers["X-CF-Email-Envelope"],
      first.body.buffer, first.headers["X-CF-Email-Signature"])).toBe(false);
  });

  it("allows the empty SMTP reverse path used by bounce messages", async () => {
    const { message, rejects } = makeMessage(RAW);
    message.from = "";
    await worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET });
    expect(rejects).toEqual([]);
    expect(fetchSpy).toHaveBeenCalledOnce();
  });

  it.each(["", "Name <recipient@test.example>", "bad\r\n@test.example", "bad\n@test.example", "x@test.example\n", "x@-bad.example", "x@bad..example", "a".repeat(65) + "@example.com"])(
    "rejects invalid SMTP recipient %j before posting", async (address) => {
      const { message, rejects } = makeMessage(RAW);
      message.to = address;
      await worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET });
      expect(rejects).toEqual(["worker received invalid SMTP envelope"]);
      expect(fetchSpy).not.toHaveBeenCalled();
    },
  );

  it("rejects the message when RAILS_INGRESS_URL is missing", async () => {
    const env = { RAILS_INGRESS_URL: "", INGRESS_SECRET: SECRET };
    const { message, rejects } = makeMessage(RAW);

    await worker.email(message as any, env);

    expect(rejects[0]).toMatch(/missing RAILS_INGRESS_URL/);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("rejects the message when INGRESS_SECRET is missing", async () => {
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: "" };
    const { message, rejects } = makeMessage(RAW);

    await worker.email(message as any, env);

    expect(rejects[0]).toMatch(/missing .*INGRESS_SECRET/);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("rejects when the upstream fetch throws", async () => {
    fetchSpy.mockRejectedValueOnce(new Error("DNS fail"));
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET };
    const { message, rejects } = makeMessage(RAW);

    await worker.email(message as any, env);

    expect(rejects).toEqual(["upstream fetch failed"]);
  });

  it("aborts a stalled ingress request after 15 seconds", async () => {
    vi.useFakeTimers();
    fetchSpy.mockImplementationOnce((_url, options) => new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => reject(new Error("aborted")));
    }));
    const { message, rejects } = makeMessage(RAW);
    const delivery = worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET });
    // Signing uses async Web Crypto, so wait until fetch starts before advancing timers.
    await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalledOnce());
    await vi.advanceTimersByTimeAsync(15_000);
    await delivery;
    expect(fetchSpy.mock.calls[0][1].signal.aborted).toBe(true);
    expect(rejects).toEqual(["upstream fetch timed out"]);
  });

  it("refuses redirects and clears the timeout after delivery", async () => {
    vi.useFakeTimers();
    await worker.email(makeMessage(RAW).message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET });
    const options = fetchSpy.mock.calls[0][1];
    expect(options.redirect).toBe("manual");
    await vi.advanceTimersByTimeAsync(15_000);
    expect(options.signal.aborted).toBe(false);
  });

  it("rejects an ingress redirect response", async () => {
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 302, headers: { Location: "https://other.test" } }));
    const { message, rejects } = makeMessage(RAW);
    await worker.email(message as any, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET });
    expect(rejects).toEqual(["upstream returned 302"]);
    expect(fetchSpy).toHaveBeenCalledOnce();
  });

  it("signature covers tampered bodies differently", async () => {
    // Sanity check: two different bodies produce two different signatures.
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET };

    await worker.email(makeMessage(RAW).message as any, env);
    const sig1 = fetchSpy.mock.calls[0][1].headers["X-CF-Email-Signature"];

    fetchSpy.mockClear();
    await worker.email(makeMessage(RAW + "tamper").message as any, env);
    const sig2 = fetchSpy.mock.calls[0][1].headers["X-CF-Email-Signature"];

    expect(sig1).not.toBe(sig2);
  });

  const metadata = { source: "cloudflare", data: { note: "Résumé ☁", spf: "pass", score: 0.5, flags: [true, null] } };
  const signingInput = { secret: SECRET, raw: new Uint8Array([0, 255, 13, 10, 128]), from: "sender@external.test", to: "inbox@trial.test", timestamp: "1750000000" };

  it("matches the shared v3 binary body and UTF8 metadata vector", async () => {
    const headers = await signedEmailHeaders({ ...signingInput, metadata });
    expect(headers["X-CF-Email-Signature-Version"]).toBe("3");
    expect(headers["X-CF-Email-Metadata"]).toBe("eyJzb3VyY2UiOiJjbG91ZGZsYXJlIiwiZGF0YSI6eyJub3RlIjoiUsOpc3Vtw6kg4piBIiwic3BmIjoicGFzcyIsInNjb3JlIjowLjUsImZsYWdzIjpbdHJ1ZSxudWxsXX19");
    expect(headers["X-CF-Email-Signature"]).toBe("d4e5ed55306e1619b5c40f3ec5dfea44a3131ad422a22b49ffb042069f6b720f");
    for (const changed of [{ ...metadata, source: "other" }, { ...metadata, data: { ...metadata.data, spf: "fail" } }]) {
      expect((await signedEmailHeaders({ ...signingInput, metadata: changed }))["X-CF-Email-Signature"]).not.toBe(headers["X-CF-Email-Signature"]);
    }
  });

  it("forwards opt-in metadata while preserving raw MIME and normal transport policy", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1750000000000);
    const { message, rejects } = makeMessage(RAW);
    await forwardEmail(message, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET }, { metadata });
    expect(rejects).toEqual([]);
    const options = fetchSpy.mock.calls[0][1];
    expect(options.headers).toEqual(await signedEmailHeaders({ ...signingInput, raw: new TextEncoder().encode(RAW), metadata }));
    expect(options.redirect).toBe("manual");
    expect(new TextDecoder().decode(options.body)).toBe(RAW);
  });

  it.each([null, {}, { source: "Cloudflare", data: {} }, { source: "a\n", data: {} },
    { source: "a".repeat(129), data: {} }, { source: "a", data: [] },
    { source: "a", data: {}, extra: true }, { source: "a", data: { x: undefined } },
    { source: "a", data: { x: NaN } }, { source: "a", data: { x: new Date() } },
    { source: "a", data: { x: "\uD800" } }, { source: "a", data: { "\uDC00": true } },
    { source: "a", data: { x: "x".repeat(16384) } }])("rejects malformed metadata without downgrading to v2 (%j)", async (invalid) => {
    await expect(signedEmailHeaders({ ...signingInput, metadata: invalid })).rejects.toThrow();
    const { message, rejects } = makeMessage(RAW);
    await forwardEmail(message, { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET }, { metadata: invalid });
    expect(rejects).toEqual(["worker could not sign envelope or provider metadata"]);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("bounds metadata nesting including cyclic data", async () => {
    const data: any = {};
    let node = data;
    for (let i = 0; i < 6; i++) { node.child = {}; node = node.child; }
    await expect(signedEmailHeaders({ ...signingInput, metadata: { source: "a", data } })).resolves.toBeDefined();
    node.child = {};
    await expect(signedEmailHeaders({ ...signingInput, metadata: { source: "a", data } })).rejects.toThrow();
    data.child = data;
    await expect(signedEmailHeaders({ ...signingInput, metadata: { source: "a", data } })).rejects.toThrow();
  });

  it("enforces the encoded metadata size boundary", async () => {
    // The JSON wrapper occupies 33 UTF8 bytes; 12288 bytes encode to 16384 characters.
    const atLimit = { source: "a", data: { text: "x".repeat(12288 - 33) } };
    const headers = await signedEmailHeaders({ ...signingInput, metadata: atLimit });
    expect(headers["X-CF-Email-Metadata"]).toHaveLength(16384);
    atLimit.data.text += "x";
    await expect(signedEmailHeaders({ ...signingInput, metadata: atLimit })).rejects.toThrow(/16384/);
  });
});
