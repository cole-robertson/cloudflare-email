import { describe, it, expect, vi } from "vitest";
import { checkSubdomains } from "../scripts/check-subdomains.mjs";

function probes() {
  let id = 0;
  return () => `fresh-${++id}`;
}
const cloudflare = [{ priority: 10, exchange: "route1.mx.cloudflare.net" }];

describe("subdomain setup DNS observations", () => {
  it("checks chosen exact names plus fresh labels without claiming delivery", async () => {
    const lookup = vi.fn(async () => cloudflare);
    const report = await checkSubdomains({ base: "in.example.com", labels: ["acme"] }, lookup, probes());
    expect(lookup.mock.calls.map(call => call[0])).toEqual(["acme.in.example.com", "fresh-1.in.example.com", "fresh-2.in.example.com"]);
    expect(report.dns_observation).toBe("cloudflare_mx_observed_for_all_names");
    expect(report.delivery_verified).toBe(false);
  });

  it("reports an exact-name exception even when fresh probes resolve", async () => {
    const report = await checkSubdomains({ base: "in.example.com", labels: ["acme"] }, async domain => {
      if (domain.startsWith("acme.")) throw Object.assign(new Error("no answer"), { code: "ENODATA" });
      return cloudflare;
    }, probes());
    expect(report.dns_observation).toBe("needs_attention");
    expect(report.checks[0].status).toBe("unknown");
  });

  it.each([
    { mx: [] }, { mx: [{ priority: 0, exchange: "." }] },
    { mx: [{ priority: 10, exchange: "mx.example.com" }] },
    { mx: [...cloudflare, { priority: 5, exchange: "mx.other.test" }] }
  ])("does not accept absent, null, foreign or mixed MX: $mx", async ({ mx }) => {
    const report = await checkSubdomains({ base: "in.example.com" }, async () => mx, probes());
    expect(report.dns_observation).toBe("needs_attention");
  });

  it("preserves DNS timeout uncertainty", async () => {
    const report = await checkSubdomains({ base: "in.example.com" }, async () => { throw Object.assign(new Error("timeout"), { code: "ETIMEOUT" }); }, probes());
    expect(report.checks.every(check => check.status === "unknown")).toBe(true);
    expect(report.delivery_verified).toBe(false);
  });

  it("rejects malformed domains and nested labels before DNS", async () => {
    const lookup = vi.fn();
    for (const base of ["*.example.com", "https://example.com", "a@b.com", "localhost", "a..com"]) {
      await expect(checkSubdomains({ base }, lookup)).rejects.toThrow();
    }
    await expect(checkSubdomains({ base: "example.com", labels: ["nested.acme"] }, lookup)).rejects.toThrow();
    expect(lookup).not.toHaveBeenCalled();
  });
});
