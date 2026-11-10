-- The manual tags save (utility-tags plan §3.5): the user's exact set
-- becomes the display set AND the manual set, and the row's auto path
-- closes — one statement, so the freeze itself is atomic (all three
-- fields or nothing; the tags_source flip is what auto_meta_upgrade's
-- guard reads).
update thread set tags = $1, tags_manual = $1, tags_source = 'manual'
where id = $2
