-- Boot sweep (tui-pairing plan, hygiene): a node whose credential has
-- gone idle past NEXUS_NODE_IDLE_DAYS is deleted — a crashed TUI has a
-- week (the default) to relaunch and re-stamp last_seen; the env var's
-- 0 disables the sweep entirely (the caller never runs this query then).
--
-- last_seen_at is bumped on every authenticated connect AND on clean
-- disconnect, so a TUI connected right up to a server shutdown carries
-- a fresh stamp into this sweep and a daily-driver credential is never
-- taken mid-use; never-connected rows expire from created_at. Sweeping
-- does not rewrite roster history (roster rows are transcript text, not
-- FKs): the target simply stops resolving, and env routing to it fails
-- as the ordinary unknown-target tool error naming the attached list.
delete from node
where coalesce(last_seen_at, created_at) < now() - make_interval(days => $1)
returning name
