-- Hard delete (token revoke): removing the row removes the node's
-- authority.
delete from node where id = $1
