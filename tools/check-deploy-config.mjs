import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// Resolve the repository config from this script so the guard behaves the
// same way from the repository root and from worker/ (where npm deploy runs).
const configPath = fileURLToPath(new URL("../wrangler.toml", import.meta.url));
const config = await readFile(configPath, "utf8");
const hasProductionRoute = /\[\[routes\]\][\s\S]*?^pattern\s*=\s*"(?![^"\n]*workers\.dev)[^"]+"/m.test(config);
const devMode = /^DEV_MODE\s*=\s*"true"\s*$/m.test(config);
const identityAuth = /^DEV_ALLOW_IDENTITY_AUTH\s*=\s*"true"\s*$/m.test(config);

if (hasProductionRoute && (devMode || identityAuth)) {
  console.error("Deploy blocked: a production route is combined with development authentication.");
  console.error("Resolve this by enabling Clerk authentication, or by disabling DEV_MODE and using DEVICE_ID_AUTH=true with mandatory request signatures.");
  process.exit(1);
}

console.log("Deploy configuration passed the development-auth guard.");
