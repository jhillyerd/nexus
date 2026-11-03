-- Model metadata upgrade (utility-tags plan §3.6): ONE update guarded
-- by BOTH provenance columns — it lands only while title_source AND
-- tags_source are 'auto' together. The refusal is whole-update, not
-- per-side: a manual rename OR a manual tag edit each closes the
-- ENTIRE auto path forever (neither column ever returns to 'auto'),
-- and a manual save racing an in-flight apply is refused here
-- atomically. Twin of the registry's in-memory UpgradeAutoTitle guard.
-- Rowcount is the guard outcome.
update session set title = $1, tags = $3
where id = $2
  and title_source = 'auto'
  and tags_source = 'auto'
