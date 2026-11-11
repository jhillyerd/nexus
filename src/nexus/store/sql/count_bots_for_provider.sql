-- How many bots point at this provider — the provider registry's delete
-- guard's bot half (409 while > 0, alongside count_threads_for_provider;
-- prefer disabling). A store COUNT, never a call into the bot registry.
select count(*)::int8 as bots
from bot
where provider_id = $1
