-- Boot sweep (tui-pairing plan, hygiene): a node whose credential has
-- gone idle past NEXUS_NODE_IDLE_DAYS is deleted — a crashed TUI has a
-- week (the default) to relaunch and re-stamp last_seen; the env var's
-- 0 disables the sweep entirely (the caller never runs this query then).
--
-- last_seen_at is bumped on every authenticated connect AND at every
-- close mist reports (the route's on_close fires for any shutdown
-- reason, valid or otherwise — clean client close, replace-kill
-- teardown, server shutdown), so last_seen tracks the last OBSERVED
-- activity of a live connection and a daily-driver TUI is never taken
-- mid-use. A hard VM kill can leave connect-time staleness behind; the
-- idle window bounds it (the plan's "a crashed TUI has a week").
-- Sweeping does not rewrite roster history (roster rows are transcript
-- text, not FKs): the target simply stops resolving, and env routing
-- to it fails as the ordinary unknown-target tool error naming the
-- attached list.
delete from node
where coalesce(last_seen_at, created_at) < now() - make_interval(days => $1)
returning name
