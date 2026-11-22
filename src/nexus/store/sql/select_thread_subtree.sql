-- Return a thread and all of its cascaded channel descendants, ordered by id.
with recursive subtree as (
  select id
  from thread
  where id = $1
  union all
  select child.id
  from thread child
  join subtree s on child.parent_thread_id = s.id
)
select id
from subtree
order by id
