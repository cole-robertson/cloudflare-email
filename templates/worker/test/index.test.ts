import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import worker from "../src/index";

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

async function verifyHmac(secret: string, ts: string, body: ArrayBuffer, hex: string) {
  const enc = new TextEncoder();
  const prefix = enc.encode(`${ts}.`);
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
    globalThis.fetch = fetchSpy as unknown as typeof fetch;
  });

  afterEach(() => {
    vi.restoreAllMocks();
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
    expect(ts).toMatch(/^\d+$/);
    expect(sig).toMatch(/^[0-9a-f]{64}$/);

    // Body bytes match the input.
    const sentBytes = opts.body as Uint8Array;
    expect(new TextDecoder().decode(sentBytes)).toBe(RAW);

    // And the signature verifies against the input.
    const ok = await verifyHmac(SECRET, ts, sentBytes.buffer, sig);
    expect(ok).toBe(true);
  });

  it("rejects the message when upstream returns non-2xx", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("server error", { status: 503 }));
    const env = { RAILS_INGRESS_URL: URL_, INGRESS_SECRET: SECRET };
    const { message, rejects } = makeMessage(RAW);

    await worker.email(message as any, env);

    expect(rejects).toEqual(["upstream returned 503"]);
  });

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

    expect(rejects[0]).toMatch(/upstream fetch failed: DNS fail/);
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
});
