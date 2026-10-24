-- Model-title upgrade (utility-titles plan §4.4): the guard is provenance
-- ONLY — the heuristic placeholder may be upgraded while the title is still
-- auto-generated; a manual rename wins forever. Twin of the registry's
-- in-memory UpgradeAutoTitle guard.
update session set title = $1
where id = $2 and title_source = 'auto'
