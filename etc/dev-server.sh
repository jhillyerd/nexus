#!/usr/bin/env bash
# Dev server launcher — run from the main checkout or any worktree.
#
#   etc/dev-server.sh
#
# The dev database is a compose singleton: docker-compose.yml pins the
# project name (`nexus`), so `up -d --wait` from any worktree reaches the
# same container/volume, starts it if needed, waits for its healthcheck
# (the server fails fast if Postgres is unreachable), and is a no-op
# while it already runs — from any checkout: the compose file carries no
# worktree-relative paths (no bind mounts), so its config hash does not
# vary per checkout. Schema applies via the migrate runner below
# (idempotent DDL — cheap no-op when the volume is already current).
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

cd "$root"

docker compose up -d --wait
gleam run -m nexus/store/migrate
gleam run -m nexus/dev_seed && gleam run
