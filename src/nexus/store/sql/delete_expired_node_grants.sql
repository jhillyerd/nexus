-- Boot sweep (tui-pairing plan Phase D wires the call): expired
-- grants are pure garbage — the plaintext is gone the moment the mint
-- answered, so the row's only remaining purpose was refusing codes.
delete from node_grant where expires_at < now()
