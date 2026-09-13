import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { retainEmail, deliverRetainedEmail, consumeRetainedEmails, sweepRetainedEmails } from "../src/index.js";

const prefix = "cloudflare-email/pending/";
const raw = new Uint8Array([70, 114, 111, 109, 58, 32, 120, 13, 10, 13, 10, 0, 255]);
function message() {
  return { from: "sender@example.com", to: "inbox@example.com", rawSize: raw.length,
    raw: new Response(raw).body, setReject: vi.fn() };
}

function setup() {
  const objects = new Map<string, Uint8Array>();
  const bucket = {
    put: vi.fn(async (key: string, value: Uint8Array | string) => {
      objects.set(key, typeof value === "string" ? new TextEncoder().encode(value) : value.slice());
    }),
    get: vi.fn(async (key: string) => {
      const bytes = objects.get(key);
      return bytes ? { size: bytes.length, body: new Response(bytes).body,
        text: async () => new TextDecoder().decode(bytes) } : null;
    }),
    delete: vi.fn(async (key: string) => { objects.delete(key); }),
    list: vi.fn(async ({ prefix, cursor, limit }) => {
      const keys = [...objects.keys()].filter(key => key.startsWith(prefix) && (!cursor || key > cursor)).sort();
      const page = keys.slice(0, limit);
      return { objects: page.map(key => ({ key })), truncated: keys.length > limit, cursor: page.at(-1) };
    }),
  };
  const env = { RAILS_INGRESS_URL: "https://rails.example.com/ingress",
    INGRESS_SECRET: "secret", INBOUND_EMAIL_STORE: bucket, INBOUND_EMAIL_QUEUE: { send: vi.fn() } };
  return { env, bucket, objects };
}

describe("durable inbound", () => {
  beforeEach(() => { vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
    vi.spyOn(console, "warn").mockImplementation(() => {}); });
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.useRealTimers(); });

  it("commits raw and context before acknowledgement and queues only a pointer", async () => {
    const { env, bucket, objects } = setup();
    env.INBOUND_EMAIL_QUEUE.send.mockImplementation(async ({ key }) => { expect(objects.has(key)).toBe(true); });
    const result = await worker.email(message(), env);
    expect(bucket.put).toHaveBeenCalledTimes(1);
    expect(env.INBOUND_EMAIL_QUEUE.send).toHaveBeenCalledWith({ version: 1, key: result.key });
    expect(fetch).not.toHaveBeenCalled();
  });

  it("does not acknowledge failed storage or enqueue a missing payload", async () => {
    const { env, bucket } = setup();
    bucket.put.mockRejectedValue(new Error("secret failure"));
    const archive = vi.fn();
    await expect(retainEmail(message(), env, { archive })).rejects.toThrow("durable storage unavailable");
    expect(archive).not.toHaveBeenCalled();
    expect(env.INBOUND_EMAIL_QUEUE.send).not.toHaveBeenCalled();
    expect(JSON.stringify(vi.mocked(console.warn).mock.calls)).not.toContain("secret failure");
  });

  it("fails closed when durable infrastructure is missing or mode is misspelled", async () => {
    const { env } = setup();
    await expect(worker.email(message(), { ...env, INBOUND_EMAIL_STORE: undefined })).rejects.toThrow("configuration invalid");
    expect(() => worker.email(message(), { ...env, INBOUND_DELIVERY_MODE: "durabel" })).toThrow("INBOUND_DELIVERY_MODE");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("direct fallback still drains the existing R2 backlog through scheduled recovery", async () => {
    const { env, objects } = setup();
    await worker.email(message(), env);
    const fallback = { ...env, INBOUND_DELIVERY_MODE: "direct" };
    await worker.email(message(), fallback);
    expect(fetch).toHaveBeenCalledTimes(1);
    const tasks = [];
    worker.scheduled({}, fallback, { waitUntil: task => tasks.push(task) });
    await Promise.all(tasks);
    expect(fetch).toHaveBeenCalledTimes(2);
    expect(objects.size).toBe(0);
  });

  it.each(["error", "timeout"])("retains and enqueues when a secondary archive has an %s", async failure => {
    const { env, objects } = setup();
    vi.useFakeTimers();
    const archive = vi.fn(async ({ raw: bytes, from, to, key }) => {
      expect(objects.has(key)).toBe(true);
      expect(bytes).toEqual(raw);
      expect(from).toBe("sender@example.com");
      expect(to).toBe("inbox@example.com");
      if (failure === "error") throw new Error("private archive error");
      await new Promise(() => {});
    });
    const pending = retainEmail(message(), env, { archive });
    await vi.advanceTimersByTimeAsync(10_001);
    const { key } = await pending;
    expect(archive).toHaveBeenCalledTimes(1);
    expect(objects.has(key)).toBe(true);
    expect(env.INBOUND_EMAIL_QUEUE.send).toHaveBeenCalledWith({ version: 1, key });
    expect(JSON.stringify(vi.mocked(console.warn).mock.calls)).not.toContain("private archive error");
  });

  it("recovers failed enqueue through scheduled scanning", async () => {
    const { env, objects } = setup();
    env.INBOUND_EMAIL_QUEUE.send.mockRejectedValue(new Error("unavailable"));
    const { key } = await retainEmail(message(), env);
    expect(objects.has(key)).toBe(true);
    await sweepRetainedEmails(env);
    expect(objects.has(key)).toBe(false);
    expect(new Uint8Array(vi.mocked(fetch).mock.calls[0][1].body)).toEqual(raw);
  });

  it.each([401, 413, 429, 500, 503, 302])("retains HTTP %s until recovery, even after queue exhaustion", async status => {
    const { env, objects } = setup();
    const { key } = await retainEmail(message(), env);
    vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status }));
    const item = { body: { version: 1, key }, ack: vi.fn(), retry: vi.fn() };
    await consumeRetainedEmails({ messages: [item] }, env);
    expect(item.ack).not.toHaveBeenCalled();
    expect(item.retry).toHaveBeenCalled();
    expect(objects.has(key)).toBe(true);
    // No queue redelivery: recovery depends exclusively on the scheduled sweep.
    await sweepRetainedEmails(env);
    expect(objects.has(key)).toBe(false);
  });

  it("replays lost HTTP acknowledgements with identical bytes and metadata but fresh signatures", async () => {
    const { env, objects } = setup();
    const { key } = await retainEmail(message(), env, { metadata: { source: "provider", data: { auth: "pass" } } });
    vi.spyOn(Date, "now").mockReturnValue(1_800_000_000_000);
    vi.mocked(fetch).mockRejectedValueOnce(new Error("lost response"));
    await expect(deliverRetainedEmail(key, env)).rejects.toThrow("handoff incomplete");
    expect(objects.has(key)).toBe(true);
    vi.mocked(Date.now).mockReturnValue(1_800_000_600_000);
    await deliverRetainedEmail(key, env);
    const [first, second] = vi.mocked(fetch).mock.calls.map(call => call[1]);
    expect(first.body).toEqual(second.body);
    expect(first.headers["X-CF-Email-Metadata"]).toEqual(second.headers["X-CF-Email-Metadata"]);
    expect(first.headers["X-CF-Email-Envelope"]).toEqual(second.headers["X-CF-Email-Envelope"]);
    expect(first.headers["X-CF-Email-Signature"]).not.toEqual(second.headers["X-CF-Email-Signature"]);
  });

  it("does not ACK a failed completion delete; missing completed keys ACK without resending", async () => {
    const { env, bucket, objects } = setup();
    const { key } = await retainEmail(message(), env);
    bucket.delete.mockRejectedValueOnce(new Error("unavailable"));
    const item = { body: { version: 1, key }, ack: vi.fn(), retry: vi.fn() };
    await consumeRetainedEmails({ messages: [item] }, env);
    expect(item.ack).not.toHaveBeenCalled();
    expect(objects.has(key)).toBe(true);
    await consumeRetainedEmails({ messages: [item] }, env);
    await consumeRetainedEmails({ messages: [item] }, env);
    expect(fetch).toHaveBeenCalledTimes(2);
    expect(item.ack).toHaveBeenCalledTimes(2);
  });

  it("advances pages past poison entries and wraps to retry them", async () => {
    const { env, objects, bucket } = setup();
    for (let i = 0; i < 12; i++) await retainEmail(message(), env);
    vi.mocked(fetch).mockResolvedValue(new Response(null, { status: 503 }));
    await sweepRetainedEmails(env);
    await sweepRetainedEmails(env);
    await sweepRetainedEmails(env);
    expect(fetch).toHaveBeenCalledTimes(12);
    expect([...objects.keys()].filter(key => key.startsWith(prefix))).toHaveLength(12);
    expect(objects.has("cloudflare-email/state/sweep")).toBe(false);
    await sweepRetainedEmails(env);
    expect(fetch).toHaveBeenCalledTimes(17);
    expect(bucket.list.mock.calls[1][0].cursor).toBeTruthy();
  });

  it("rejects oversize messages without retaining incomplete bodies", async () => {
    const { env, objects } = setup();
    const input = message();
    input.rawSize = 0;
    await retainEmail(input, { ...env, MAX_EMAIL_BYTES: "2" });
    expect(input.setReject).toHaveBeenCalledWith("message exceeds size limit");
    expect(objects.size).toBe(0);
  });
});
