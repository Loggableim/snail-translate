import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    include: ["src/**/*.test.ts"],
    poolOptions: {
      workers: {
        main: "../worker/src/index.ts",
        isolatedStorage: true,
        singleWorker: true,
        wrangler: { configPath: "../wrangler.toml" },
      },
    },
  },
});
