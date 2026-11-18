-- Record a successful exchange under this grant (best-effort at the
-- route, like touch_node): diagnostics for the info pane — how many
-- TUIs paired, when last. use_count is server-side increment, so two
-- concurrent exchanges cannot lose a count.
update node_grant
set use_count = use_count + 1, last_used_at = now()
where id = $1
