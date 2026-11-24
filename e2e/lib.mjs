//// Shared Postgres harness helpers for the deterministic e2e suites
//// (browser.spec.mjs, node.spec.mjs, tui.spec.mjs — validation only).

import { spawn } from "node:child_process";

/// Canonical table truncation list covering every mutable schema table across
/// `0001_initial.sql` and `0002_workspace_sandbox.sql`. Kept in one place so
/// the three e2e suites cannot drift when new tables are added.
export const E2E_TRUNCATE_SQL =
  "truncate thread_message, workspace, node_grant, node, thread, bot, provider cascade;";

/// Derive Nexus's `NEXUS_PG_*` environment variables from a PostgreSQL URL so
/// every suite respects `E2E_DATABASE_URL` uniformly (local docker compose on
/// 5433 vs CI's postgres:17 service on 5432 with password).
export function pgEnvFromUrl(databaseUrl) {
  const pg = new URL(databaseUrl);
  return {
    NEXUS_PG_HOST: pg.hostname,
    NEXUS_PG_PORT: pg.port || "5432",
    NEXUS_PG_DATABASE: pg.pathname.slice(1),
    NEXUS_PG_USER: decodeURIComponent(pg.username),
    ...(pg.password ? { NEXUS_PG_PASSWORD: decodeURIComponent(pg.password) } : {}),
  };
}

/// Reset the shared e2e database to a clean slate before booting Nexus.
export function resetDatabase(databaseUrl) {
  return new Promise((resolve, reject) => {
    const child = spawn("psql", ["-q", databaseUrl, "-c", E2E_TRUNCATE_SQL], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", (err) =>
      reject(
        new Error(
          `psql not found (${err.message}) — it ships with the Postgres the suite already requires`,
        ),
      ),
    );
    child.on("exit", (code) =>
      code === 0
        ? resolve()
        : reject(new Error(`database reset failed (${code}):\n${out}`)),
    );
  });
}
