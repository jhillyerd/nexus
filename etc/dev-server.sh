#!/usr/bin/env bash
# Dev server launcher — run from the main checkout or any worktree.
#
#   etc/dev-server.sh [--reset | -r]
#
# --reset (or -r) tears down the dev database first (compose `down -v`, which
# deletes the named volume), so everything after starts against an empty
# db: migrate builds the schema, dev_seed re-seeds, and the server boots
# with no history. Destructive — every thread in the shared singleton is
# lost, from whichever checkout you run this.
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

reset=0
for arg in "$@"; do
  case "$arg" in
    --reset | -r) reset=1 ;;
    -h | --help)
      # Print the header comment block (everything between the shebang and
      # the first line of code), so the help text cannot drift out of sync
      # with the file the way a hardcoded line range would.
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } !/^#/ { exit }' "$0"
      exit 0
      ;;
    *)
      echo "dev-server.sh: unknown argument '$arg' (try --help)" >&2
      exit 2
      ;;
  esac
done

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

if [ "$reset" = 1 ]; then
  # `down -v` removes this project's containers, network, and named
  # volumes — with the pinned project name that is exactly the one
  # `nexus-db-data` volume, from any worktree. No `--remove-orphans`:
  # this reset owns the db container and nothing else, and orphan
  # cleanup would also tear down containers this file does not define.
  echo "dev-server.sh: --reset, destroying the dev database volume"
  docker compose down -v
fi

docker compose up -d --wait
gleam run -m nexus/store/migrate
gleam run -m nexus/dev_seed && gleam run
