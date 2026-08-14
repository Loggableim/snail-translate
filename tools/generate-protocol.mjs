import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = path.join(root, "shared", "dto", "v1", "messages.json");
const outputDir = path.join(root, "shared", "dto", "v1", "generated");
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const types = schema.definitions.MessageType.enum;
const version = schema.protocolVersion;

if (!Number.isInteger(version) || version < 1) {
  throw new Error("messages.json must define a positive integer protocolVersion");
}

fs.mkdirSync(outputDir, { recursive: true });

const tsTypes = types.map((type) => `  | "${type}"`).join("\n");
const dartTypes = types
  .map((type) => `  ${type.replace(/_([a-z])/g, (_, c) => c.toUpperCase())},`)
  .join("\n");

fs.writeFileSync(
  path.join(outputDir, "protocol.ts"),
  `// GENERATED from shared/dto/v1/messages.json. Do not edit by hand.\n` +
    `export const PROTOCOL_VERSION = ${version} as const;\n` +
    `export type ProtocolMessageType =\n${tsTypes};\n`,
);

fs.writeFileSync(
  path.join(outputDir, "protocol.dart"),
  `// GENERATED from shared/dto/v1/messages.json. Do not edit by hand.\n` +
    `const int protocolVersion = ${version};\n\n` +
    `enum ProtocolMessageType {\n${dartTypes}\n}\n`,
);

console.log(`Generated protocol v${version} for ${types.length} message types.`);
