-- Model metadata upgrade (utility-tags plan §3.6): the guard is
-- provenance ONLY, on BOTH sides — the title may upgrade while
-- title_source = 'auto', the display tags may be written while
-- tags_source = 'auto'; a manual rename or a manual tag edit each close
-- their side forever, and a manual save racing an in-flight apply is
-- refused here atomically. Twin of the registry's in-memory
-- UpgradeAutoTitle guard. Rowcount is the guard outcome.
update session set title = $1, tags = $3
where id = $2
  and title_source = 'auto'
  and tags_source = 'auto'
