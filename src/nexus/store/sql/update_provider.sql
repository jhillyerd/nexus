-- Full-metadata provider update. `replace_key` ($4) decides the key
-- envelope's fate so a PATCH without an api_key keeps the stored
-- ciphertext instead of nulling it:
--   false → envelope and key_version untouched (key param ignored);
--   true  → envelope := nullif($5, ''::bytea) — a real value replaces
--           it, the '' sentinel goes keyless (NULL) — and key_version
--           := $6. (Sentinel for the same reason as insert_provider.)
-- updated_at is server-side now(), like the thread metadata writes.
update provider set
  name = $2,
  base_url = $3,
  api_key_encrypted = case when $4 then nullif($5, ''::bytea) else api_key_encrypted end,
  key_version = case when $4 then $6 else key_version end,
  enabled = $7,
  updated_at = now()
where id = $1
