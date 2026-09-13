import { afterEach, describe, expect, it, vi } from "vitest";
import { archiveEmail, relayEmail, signedEmailHeaders } from "../src/index.js";

const raw = new Uint8Array([0, 255, 13, 10, 128]);
function message(bytes = raw, rawSize = bytes.length) {
  return { from: "sender@example.com", to: "inbox@tenant.example.com", rawSize,
    raw: new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); } }) };
}
function options(overrides = {}) {
  return { resolveBackend: async () => ({ url: "https://rails.example.com/ingest", secret: "test-secret" }),
    headers: async ({ raw, from, to, backend }) => signedEmailHeaders({ raw, from, to, secret: backend.secret }),
    ...overrides };
}
afterEach(() => { vi.unstubAllGlobals(); vi.useRealTimers(); });

describe("host-controlled relay", () => {
  it("archives once before acceptance and backend lookup, signs and sends exact binary bytes", async () => {
    const order: string[] = [];
    const put = vi.fn(async (key, body, metadata) => {
      order.push("archive");
      expect(key).toBe("mail/one.eml");
      expect(body).toEqual(raw);
      expect(metadata).toEqual({ httpMetadata: { contentType: "message/rfc822" },
        customMetadata: { from: "sender@example.com", to: "inbox@tenant.example.com", size: "5" } });
    });
    const fetch = vi.fn(async (_url, init) => {
      order.push("fetch");
      expect(init.body).toEqual(raw);
      expect(init.headers.get("X-CF-Email-Signature-Version")).toBe("2");
      expect(init.redirect).toBe("manual");
      expect(init.signal).toBeInstanceOf(AbortSignal);
      return new Response(null, { status: 202 });
    });
    vi.stubGlobal("fetch", fetch);
    const result = await relayEmail(message(), options({
      archive: (args) => archiveEmail({ ...args, bucket: { put }, key: "mail/one.eml" }),
      accepts: async () => { order.push("accepts"); return true; },
      resolveBackend: async () => { order.push("backend"); return { url: "https://rails.example.com/ingest", secret: "test-secret" }; },
      headers: async (args) => {
        expect(args.archive).toEqual({ key: "mail/one.eml" });
        order.push("headers");
        return signedEmailHeaders({ ...args, secret: args.backend.secret });
      },
    }));
    expect(order).toEqual(["archive", "accepts", "backend", "headers", "fetch"]);
    expect(result).toEqual({ status: "delivered", reason: "delivered", httpStatus: 202, archiveFailed: false });
    expect(fetch).toHaveBeenCalledOnce();
    expect(put).toHaveBeenCalledOnce();
  });

  it("continues after archive failure without exposing exception content", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
    const result = await relayEmail(message(), options({ archive: async () => { throw new Error("PRIVATE EMAIL SECRET"); } }));
    expect(result).toEqual({ status: "delivered", reason: "delivered", httpStatus: 204, archiveFailed: true });
  });

  it("archives rejected recipients without resolving a backend", async () => {
    const archive = vi.fn(async () => ({ key: "retained.eml" }));
    const resolveBackend = vi.fn();
    expect(await relayEmail(message(), options({ archive, accepts: async () => false, resolveBackend })))
      .toEqual({ status: "rejected", reason: "not_accepted", archiveFailed: false });
    expect(archive).toHaveBeenCalledOnce();
    expect(resolveBackend).not.toHaveBeenCalled();
  });

  it("continues when the archive deadline expires, allowing a late archive completion", async () => {
    vi.useFakeTimers();
    let finish;
    const archive = vi.fn(() => new Promise(resolve => { finish = resolve; }));
    const fetch = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetch);
    const pending = relayEmail(message(), options({ archive, archiveTimeoutMs: 20,
      headers: async ({ archive }) => { expect(archive).toBeUndefined(); return {}; },
    }));
    await vi.advanceTimersByTimeAsync(19);
    expect(fetch).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(1);
    expect(await pending).toEqual({ status: "delivered", reason: "delivered", httpStatus: 200, archiveFailed: true });
    finish({ key: "late.eml" });
    await Promise.resolve();
    expect(fetch).toHaveBeenCalledOnce();
    expect(archive).toHaveBeenCalledOnce();
  });

  it("uses the validated URL even when the headers callback changes the backend", async () => {
    const fetch = vi.fn(async () => new Response(null, { status: 200 }));
    vi.stubGlobal("fetch", fetch);
    await relayEmail(message(), options({ headers: async ({ backend }) => {
      backend.url = "http://untrusted.example.com/secret";
      return { Authorization: "Basic private" };
    } }));
    expect(fetch.mock.calls[0][0]).toBe("https://rails.example.com/ingest");
  });

  it("bounds actual streaming bytes even when rawSize is false", async () => {
    const cancel = vi.fn();
    const stream = new ReadableStream({ start(c) { c.enqueue(raw); }, cancel });
    const archive = vi.fn();
    expect(await relayEmail({ ...message(), raw: stream, rawSize: 1 }, options({ maxEmailBytes: 4, archive })))
      .toEqual({ status: "rejected", reason: "too_large", archiveFailed: false });
    expect(cancel).toHaveBeenCalledOnce();
    expect(archive).not.toHaveBeenCalled();
  });

  it("rejects declared oversize or invalid envelopes without reading", async () => {
    const getReader = vi.fn();
    expect((await relayEmail({ ...message(), raw: { getReader }, rawSize: 100 }, options({ maxEmailBytes: 50 }))).reason).toBe("too_large");
    expect((await relayEmail({ ...message(), raw: { getReader }, to: "bad\r\naddress" }, options())).reason).toBe("invalid_envelope");
    expect(getReader).not.toHaveBeenCalled();
  });

  it("reports read failures and invalid chunks without forwarding", async () => {
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    for (const stream of [new ReadableStream({ start(c) { c.error(new Error("secret")); } }),
      new ReadableStream({ start(c) { c.enqueue("bad chunk"); c.close(); } })]) {
      expect(await relayEmail({ ...message(), raw: stream }, options()))
        .toEqual({ status: "failed", reason: "unreadable", archiveFailed: false });
    }
    expect(fetch).not.toHaveBeenCalled();
  });

  it.each(["http://rails.example.com", "https://user:secret@example.com", "https://example.com/#secret", "ftp://example.com", "invalid"])
    ("rejects unsafe backend %s", async (url) => {
      const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
      expect((await relayEmail(message(), options({ resolveBackend: async () => ({ url }) }))).reason).toBe("invalid_backend");
      expect(fetch).not.toHaveBeenCalled();
    });

  it("supports a host-selected loopback backend and Basic headers", async () => {
    const fetch = vi.fn(async (url, init) => {
      expect(url).toBe("http://127.0.0.1:3000/ingest");
      expect(init.headers.get("Authorization")).toBe("Basic dGVzdDp0ZXN0");
      expect(init.body).toEqual(raw);
      return new Response(null, { status: 200 });
    });
    vi.stubGlobal("fetch", fetch);
    const result = await relayEmail(message(), options({
      resolveBackend: async ({ to }) => ({ url: to.includes("tenant") ? "http://127.0.0.1:3000/ingest" : "https://other.example.com" }),
      headers: async () => ({ Authorization: "Basic dGVzdDp0ZXN0", "Content-Type": "message/rfc822" }),
    }));
    expect(result.status).toBe("delivered");
  });

  it("leaves Unicode and legacy address shapes to host acceptance with custom headers", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 200 })));
    const from = "séndér@example.com";
    const to = '"quoted local"@TENANT.example.com';
    const accepts = vi.fn(async (envelope) => {
      expect(envelope).toEqual({ from, to });
      return true;
    });
    expect((await relayEmail({ ...message(), from, to }, options({ accepts,
      headers: async () => ({ Authorization: "Basic dGVzdDp0ZXN0" }),
    }))).status).toBe("delivered");
    expect(accepts).toHaveBeenCalledOnce();
  });

  it.each([301, 400, 401, 413, 422, 429, 500, 503])("returns HTTP %i without reading response content or retrying", async (status) => {
    const cancel = vi.fn();
    const response = new Response(new ReadableStream({ cancel }), { status });
    const text = vi.spyOn(response, "text");
    const fetch = vi.fn(async () => response); vi.stubGlobal("fetch", fetch);
    expect(await relayEmail(message(), options())).toEqual({ status: "failed", reason: "http_status", httpStatus: status, archiveFailed: false });
    expect(text).not.toHaveBeenCalled();
    expect(cancel).toHaveBeenCalledOnce();
    expect(fetch).toHaveBeenCalledOnce();
  });

  it("does not wait for an unresponsive response cancellation", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(new ReadableStream({ cancel: () => new Promise(() => {}) }), { status: 200 })));
    expect((await relayEmail(message(), options())).status).toBe("delivered");
  });

  it("aborts fetch on the configured timeout and returns no exception text", async () => {
    vi.useFakeTimers();
    vi.stubGlobal("fetch", vi.fn(async (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(new Error("private backend")));
    })));
    const pending = relayEmail(message(), options({ timeoutMs: 25, headers: async () => ({}) }));
    await vi.advanceTimersByTimeAsync(25);
    expect(await pending).toEqual({ status: "failed", reason: "timeout", archiveFailed: false });
  });

  it.each([
    [{ accepts: async () => { throw new Error("secret"); } }, "acceptance_failed"],
    [{ resolveBackend: async () => { throw new Error("secret"); } }, "backend_failed"],
    [{ resolveBackend: async () => null }, "invalid_backend"],
    [{ headers: async () => { throw new Error("secret"); } }, "headers_failed"],
    [{ headers: async () => ({ "Bad\nHeader": "secret" }) }, "headers_failed"],
    [{ maxEmailBytes: 0 }, "invalid_options"],
    [{ timeoutMs: Infinity }, "invalid_options"],
    [{ timeoutMs: 2 ** 31 }, "invalid_options"],
    [{ archive: true }, "invalid_options"],
    [{ archiveTimeoutMs: 0 }, "invalid_options"],
    [{ archiveTimeoutMs: 2 ** 31 }, "invalid_options"],
  ])("returns safe callback/configuration failure %#", async (overrides, reason) => {
    expect(await relayEmail(message(), options(overrides))).toEqual({ status: "failed", reason, archiveFailed: false });
  });

  it("returns fetch failures without backend secrets", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("secret-url"); }));
    expect(await relayEmail(message(), options())).toEqual({ status: "failed", reason: "fetch_failed", archiveFailed: false });
  });
});

describe("R2 archive helper", () => {
  it("validates archive arguments before invoking the bucket", async () => {
    const put = vi.fn();
    const args = { bucket: { put }, key: "mail/id.eml", raw, from: "", to: "inbox@example.com" };
    for (const overrides of [{ key: "" }, { key: "x".repeat(1025) }, { key: "\u0000" }, { raw: "bad" },
      { from: "sender\r\n@example.com" }, { to: "" }]) {
      await expect(archiveEmail({ ...args, ...overrides })).rejects.toThrow("invalid email archive arguments");
    }
    expect(put).not.toHaveBeenCalled();
    await expect(archiveEmail(args)).resolves.toEqual({ key: "mail/id.eml" });
    expect(put.mock.calls[0][2].customMetadata.from).toBe("");
  });

  it("stores ASCII-safe envelope metadata while preserving raw Unicode mail bytes", async () => {
    const put = vi.fn();
    await archiveEmail({ bucket: { put }, key: "mail/unicode.eml", raw,
      from: "séndér@example.com", to: "inbox@tenant.example.com" });
    expect(put.mock.calls[0][1]).toEqual(raw);
    expect(put.mock.calls[0][2].customMetadata.from).toBe("s?nd?r@example.com");
  });
});
