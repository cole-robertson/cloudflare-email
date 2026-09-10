import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const [command, ...args] = process.argv.slice(2);
const envIndex = args.indexOf("--env");
const environment = args[envIndex + 1];
if (envIndex < 0 || !["development", "staging", "production"].includes(environment)) {
  console.error("Specify --env development, --env staging, or --env production.");
  process.exit(1);
}
const result = spawnSync(process.execPath, [
  fileURLToPath(new URL("../node_modules/wrangler/bin/wrangler.js", import.meta.url)),
  command, ...args,
], { stdio: "inherit" });
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
