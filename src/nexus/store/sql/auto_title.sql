-- Auto-title only while the title is still the untouched auto default.
update thread set title = $1
where id = $2 and title_source = 'auto' and title = ''
