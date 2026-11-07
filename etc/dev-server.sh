#!/usr/bin/env bash
# Dev server launcher — run from the main checkout or any worktree.
#
#   etc/dev-server.sh
#
# The dev database is a compose singleton: docker-compose.yml pins the
# project name (`nexus`), so `up -d --wait` from any worktree reaches the
# same container/volume, starts it if needed, waits for its healthcheck
# (the server fails fast if Postgres is unreachable), and is a no-op
# while it already runs. First-boot only applies sql/schema.sql, so the
# migrate runner re-applies it after (idempotent DDL — cheap no-op when
# the volume is already current).
set -euo pipefail

# Root of THIS checkout (the script lives in <root>/etc).
root="$(cd "$(dirname "$0")/.." && pwd)"

# Root of the main checkout: `.env` is untracked, so only the main
# checkout has one; worktrees find it via git's shared common dir.
main="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
main="${main%/.git}"

set -a
source "$main/.env"
set +a
export NEXUS_HTTP_BIND=0.0.0.0

cd "$root"

docker compose up -d --wait
gleam run -m nexus/store/migrate
gleam run -m nexus/dev_seed && gleam run
