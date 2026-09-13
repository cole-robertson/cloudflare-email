// Read-only public DNS check. No Cloudflare credentials or configuration writes.
import { Resolver } from "node:dns/promises";
import { randomBytes } from "node:crypto";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

const labelPattern = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

export async function checkSubdomains({ base, labels = [] }, lookup, randomLabel = () => `cf-probe-${randomBytes(8).toString("hex")}`) {
  base = String(base || "").trim().toLowerCase();
  if (base.length > 220 || base.split(".").length < 2 || !base.split(".").every(label => labelPattern.test(label))) {
    throw new Error("Provide a DNS base such as in.example.com, without @, a scheme, or *.");
  }
  if (labels.length > 10 || !labels.every(label => labelPattern.test(label) && `${label}.${base}`.length <= 253)) {
    throw new Error("Provide at most 10 comma-separated single-label subdomains, such as acme,globex.");
  }
  const probes = [randomLabel(), randomLabel()];
  const names = [...new Set([...labels, ...probes])];
  const checks = await Promise.all(names.map(async label => {
    const domain = `${label}.${base}`;
    try {
      const mx = (await lookup(domain)).map(record => ({ priority: record.priority, exchange: record.exchange.toLowerCase().replace(/\.$/, "") }));
      const cloudflare = mx.length > 0 && mx.every(record => record.exchange.endsWith(".mx.cloudflare.net"));
      return { domain, fresh_probe: probes.includes(label), status: cloudflare ? "cloudflare_mx_observed" : "other_or_missing_mx", mx };
    } catch (error) {
      return { domain, fresh_probe: probes.includes(label), status: "unknown", reason: error.code || "DNS_LOOKUP_FAILED" };
    }
  }));
  return {
    checked_at: new Date().toISOString(),
    base, dns_observation: checks.every(check => check.status === "cloudflare_mx_observed") ? "cloudflare_mx_observed_for_all_names" : "needs_attention",
    delivery_verified: false, checks,
    next_step: "Inspect the catch-all Worker rule, register two exact domains/mailboxes in Rails, and send real test emails. MX answers do not verify account ownership, Email Routing acceptance, Worker delivery, or Rails persistence."
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const { values } = parseArgs({ options: { base: { type: "string" }, labels: { type: "string" }, help: { type: "boolean" } } });
    if (values.help) {
      console.log("npm run check:subdomains -- --base in.example.com [--labels acme,globex]\nRead-only DNS observations, including two fresh labels. This does not verify email delivery.");
    } else {
      const resolver = new Resolver({ timeout: 2000, tries: 1 });
      const labels = values.labels ? values.labels.split(",").map(label => label.trim().toLowerCase()) : [];
      const report = await checkSubdomains({ base: values.base, labels }, domain => resolver.resolveMx(domain));
      console.log(JSON.stringify(report, null, 2));
      if (report.dns_observation === "needs_attention") process.exitCode = 1;
    }
  } catch (error) {
    console.error(error.message);
    console.error("Usage: npm run check:subdomains -- --base in.example.com [--labels acme,globex]");
    process.exitCode = 1;
  }
}
