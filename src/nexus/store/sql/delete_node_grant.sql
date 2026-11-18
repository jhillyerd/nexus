-- Revoke a pairing grant: removing the row removes the code's
-- authority (future exchanges 404 — the merged unknown/expired
-- answer). Idempotent like delete_node.
delete from node_grant where id = $1
