// Local workerd/R2 capacity smoke test. No deployment or external email.
// Node22+: npm ci --prefix templates/worker && node script/verify_durable_capacity.mjs
import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { createServer } from "node:http";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const root = fileURLToPath(new URL("../", import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), "cloudflare-email-capacity-"));
const limit = 25 * 1024 * 1024;
const secret = "synthetic-local-capacity-secret";
const accepted = [];
const failures = [];
const receiver = createServer(async (request, response) => {
  try {
    const hash = createHash("sha256");
    const signature = createHmac("sha256", secret);
    signature.update(`v2.${request.headers["x-cf-email-timestamp"]}.${request.headers["x-cf-email-envelope"]}.`);
    let size = 0;
    for await (const chunk of request) { size += chunk.length; hash.update(chunk); signature.update(chunk); }
    assert.equal(size, limit);
    assert.equal(signature.digest("hex"), request.headers["x-cf-email-signature"]);
    accepted.push(hash.digest("hex"));
    response.writeHead(204).end();
  } catch (error) {
    failures.push(error.message);
    response.writeHead(500).end();
  }
});
await new Promise(resolve => receiver.listen(0, "127.0.0.1", resolve));
const portPicker = createServer();
await new Promise(resolve => portPicker.listen(0, "127.0.0.1", resolve));
const workerPort = portPicker.address().port;
await new Promise(resolve => portPicker.close(resolve));
const url = `http://127.0.0.1:${workerPort}`;
let processHandle;
let logs = "";
try {
  await writeFile(join(temporary, "worker.js"), `
    import worker, { deliverRetainedEmail } from ${JSON.stringify(join(root, "templates/worker/src/index.js"))};
    export default {
      email: worker.email,
      async fetch(request, env) {
        const pending = await env.INBOUND_EMAIL_STORE.list({prefix: 'cloudflare-email/pending/'});
        if (new URL(request.url).pathname === '/recover') {
          // Deliberately force concurrent handoffs inside one isolate.
          await Promise.all(pending.objects.map(object => deliverRetainedEmail(object.key, env)));
        }
        const remaining = await env.INBOUND_EMAIL_STORE.list({prefix: 'cloudflare-email/pending/'});
        return Response.json({pending: remaining.objects.length});
      }
    };
  `);
  await writeFile(join(temporary, "wrangler.json"), JSON.stringify({
    name: "cloudflare-email-capacity-verification", main: "worker.js", compatibility_date: "2026-09-10",
    vars: { MAX_EMAIL_BYTES: String(limit),
      RAILS_INGRESS_URL: `http://127.0.0.1:${receiver.address().port}/`, INGRESS_SECRET: secret },
    r2_buckets: [{ binding: "INBOUND_EMAIL_STORE", bucket_name: "synthetic-capacity" }],
    queues: { producers: [{ binding: "INBOUND_EMAIL_QUEUE", queue: "synthetic-capacity" }] },
  }));
  processHandle = spawn(process.execPath,
    [join(root, "templates/worker/node_modules/wrangler/bin/wrangler.js"), "dev", "--local", "--config",
      join(temporary, "wrangler.json"), "--ip", "127.0.0.1", "--port", String(workerPort), "--inspector-port", "0"],
    { cwd: temporary, detached: true, env: { ...process.env, CLOUDFLARE_API_TOKEN: "", CLOUDFLARE_ACCOUNT_ID: "",
      WRANGLER_SEND_METRICS: "false", CI: "true" }, stdio: ["ignore", "pipe", "pipe"] });
  processHandle.stdout.on("data", value => { logs += value; });
  processHandle.stderr.on("data", value => { logs += value; });
  const deadline = Date.now() + 30_000;
  while (true) {
    try { if ((await fetch(url)).ok) break; } catch { /* starting */ }
    if (Date.now() > deadline || processHandle.exitCode !== null) throw new Error("workerd did not start");
    await delay(100);
  }
  for (const count of [1, 2]) {
    const expected = [];
    const before = accepted.length;
    await Promise.all(Array.from({ length: count }, async (_, index) => {
      const body = Buffer.alloc(limit, 65 + index);
      body.write(`From: sender@example.test\r\nTo: inbox@example.test\r\nMessage-ID: <capacity-${count}-${index}@example.test>\r\n\r\n`);
      expected.push(createHash("sha256").update(body).digest("hex"));
      const result = await fetch(`${url}/cdn-cgi/local/email?from=sender@example.test&to=inbox@example.test`,
        { method: "POST", headers: { "Content-Type": "message/rfc822" }, body, signal: AbortSignal.timeout(60_000) });
      assert.equal(result.ok, true, `retention HTTP ${result.status}: ${await result.text()}`);
    }));
    assert.equal((await (await fetch(url)).json()).pending, count);
    const recovery = await fetch(`${url}/recover`, { signal: AbortSignal.timeout(60_000) });
    assert.equal(recovery.ok, true, `handoff HTTP ${recovery.status}: ${await recovery.clone().text()}`);
    assert.equal((await recovery.json()).pending, 0);
    assert.deepEqual(failures, []);
    assert.deepEqual(accepted.slice(before).sort(), expected.sort());
    console.log(`PASS: ${count} concurrent 25 MiB message(s): R2 retained, exact bytes/HMAC verified, pending cleared`);
  }
  console.log("Local workerd smoke test passed; this does not measure or certify production isolate memory/concurrency limits.");
} catch (error) {
  console.error(logs);
  throw error;
} finally {
  if (processHandle?.pid) {
    try { process.kill(-processHandle.pid, "SIGTERM"); } catch { /* already exited */ }
    await Promise.race([new Promise(resolve => processHandle.once("exit", resolve)), delay(5000)]);
    try { process.kill(-processHandle.pid, "SIGKILL"); } catch { /* already exited */ }
  }
  receiver.closeAllConnections();
  await new Promise(resolve => receiver.close(resolve));
  await rm(temporary, { recursive: true, force: true });
}
