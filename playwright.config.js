import { defineConfig } from "playwright/test";
import { existsSync } from "node:fs";

const python = process.env.FAITH_PYTHON || (existsSync(".venv/bin/python") ? ".venv/bin/python" : "python");

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  use: {
    baseURL: "http://127.0.0.1:8765",
    browserName: "chromium",
    channel: existsSync("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") ? "chrome" : undefined,
    viewport: { width: 1440, height: 1050 },
    trace: "retain-on-failure",
    screenshot: "only-on-failure"
  },
  webServer: {
    command: `${python} -m uvicorn app.main:app --app-dir backend --host 127.0.0.1 --port 8765`,
    url: "http://127.0.0.1:8765/health",
    reuseExistingServer: false,
    env: { FAITH_DATABASE_PATH: ":memory:", FAITH_AI_PROVIDER: "local", PHOENIX_COLLECTOR_ENDPOINT: "", ARIZE_API_KEY: "", ARIZE_SPACE_ID: "", SURREAL_URL: "", ANCHOR_API_KEY: "", ELEVENLABS_API_KEY: "" }
  }
});
