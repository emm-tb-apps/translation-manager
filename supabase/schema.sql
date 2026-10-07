-- Translation Manager — cloud workspace schema.
-- One row per locale; its strings live in a jsonb array (same shape as the app's "Save All" file).
-- Every signed-in user shares the same workspace. Anonymous visitors have no access at all.

create table if not exists public.locales (
  id          uuid primary key default gen_random_uuid(),
  code        text not null,
  name        text not null default '',
  file        text not null default '',
  position    integer not null default 0,
  strings     jsonb not null default '[]'::jsonb check (jsonb_typeof(strings) = 'array'),
  version     integer not null default 1,      -- bumped on every update; the app uses it to detect concurrent edits
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid() references auth.users (id) on delete set null
);

create index if not exists locales_position_idx on public.locales (position, created_at);

-- Keep version / audit columns honest regardless of what the client sends.
create or replace function public.locales_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    new.version    := old.version + 1;
    new.created_at := old.created_at;
  else
    new.version    := 1;
    new.created_at := now();
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists locales_touch on public.locales;
create trigger locales_touch
  before insert or update on public.locales
  for each row execute function public.locales_touch();

-- Access: signed-in users only.
alter table public.locales enable row level security;

-- Supabase's default privileges also hand out TRUNCATE (which bypasses RLS), REFERENCES and
-- TRIGGER, so strip everything back to plain CRUD.
revoke all on public.locales from anon, authenticated;
grant select, insert, update, delete on public.locales to authenticated;

drop policy if exists "signed-in users can read locales"   on public.locales;
drop policy if exists "signed-in users can add locales"    on public.locales;
drop policy if exists "signed-in users can edit locales"   on public.locales;
drop policy if exists "signed-in users can delete locales" on public.locales;

create policy "signed-in users can read locales"   on public.locales for select to authenticated using (true);
create policy "signed-in users can add locales"    on public.locales for insert to authenticated with check (true);
create policy "signed-in users can edit locales"   on public.locales for update to authenticated using (true) with check (true);
create policy "signed-in users can delete locales" on public.locales for delete to authenticated using (true);

-- Roles. The owner row is added by hand in the SQL editor so no email lands in this public repo:
--   insert into public.app_roles (email, role) values ('<owner email, lowercase>', 'owner');
create table if not exists public.app_roles (
  email  text primary key check (email = lower(email)),
  role   text not null check (role in ('owner'))
);
alter table public.app_roles enable row level security;
revoke all on public.app_roles from anon, authenticated;   -- not readable from the browser at all

-- True when the signed-in user's (verified) email is listed as owner. The app uses it to show
-- "Open File (big JSON)", which replaces every locale in the shared workspace.
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.app_roles r
    where r.email = lower(coalesce(auth.jwt() ->> 'email', '')) and r.role = 'owner'
  );
$$;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.is_owner() to authenticated;

-- Activity log. Written only by a trigger on public.locales (security definer), so every saved
-- change is recorded with who made it and it can't be skipped, edited or deleted from the app.
create table if not exists public.activity_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  user_id      uuid,
  user_email   text,
  action       text not null check (action in ('created', 'updated', 'deleted')),
  locale_id    uuid,
  locale_code  text not null,
  summary      text not null,
  details      jsonb not null default '{}'::jsonb   -- per-key changes, capped at 200 keys per entry
);
create index if not exists activity_log_at_idx on public.activity_log (at desc, id desc);
alter table public.activity_log enable row level security;
revoke all on public.activity_log from anon, authenticated;
grant select on public.activity_log to authenticated;     -- read-only, append happens in the trigger
drop policy if exists "signed-in users can read the activity log" on public.activity_log;
create policy "signed-in users can read the activity log" on public.activity_log for select to authenticated using (true);

create or replace function public.locales_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  o        jsonb := case when tg_op <> 'INSERT' then old.strings else '[]'::jsonb end;
  n        jsonb := case when tg_op <> 'DELETE' then new.strings else '[]'::jsonb end;
  n_add    integer := 0;
  n_rem    integer := 0;
  n_chg    integer := 0;
  keys     jsonb := '[]'::jsonb;
  bits     text[] := '{}';
  act      text;
  row_id   uuid;
  row_code text;
  info     jsonb := '{}'::jsonb;
begin
  if tg_op = 'INSERT' then
    act := 'created'; row_id := new.id; row_code := new.code;
    bits := array['created with ' || jsonb_array_length(n) || ' strings'];
    info := jsonb_build_object('strings', jsonb_array_length(n));
  elsif tg_op = 'DELETE' then
    act := 'deleted'; row_id := old.id; row_code := old.code;
    bits := array['deleted (' || jsonb_array_length(o) || ' strings)'];
    info := jsonb_build_object('strings', jsonb_array_length(o));
  else
    act := 'updated'; row_id := new.id; row_code := new.code;
    -- key-level diff of the strings arrays (keyed by term)
    with a as (select distinct on (e ->> 'term') e ->> 'term' as term, e from jsonb_array_elements(o) e order by e ->> 'term'),
         b as (select distinct on (e ->> 'term') e ->> 'term' as term, e from jsonb_array_elements(n) e order by e ->> 'term'),
         j as (select coalesce(a.term, b.term) as term, a.e as before, b.e as after,
                      row_number() over (order by coalesce(a.term, b.term)) as rn
               from a full join b on a.term = b.term
               where a.e is distinct from b.e)
    select count(*) filter (where before is null),
           count(*) filter (where after is null),
           count(*) filter (where before is not null and after is not null),
           coalesce(jsonb_agg(jsonb_build_object(
             'key',         term,
             'change',      case when before is null then 'added' when after is null then 'removed' else 'changed' end,
             'from',        before ->> 'definition',
             'to',          after  ->> 'definition',
             'review_from', before ->> 'fuzzy',
             'review_to',   after  ->> 'fuzzy'
           ) order by term) filter (where rn <= 200), '[]'::jsonb)
      into n_add, n_rem, n_chg, keys
      from j;
    if old.code is distinct from new.code then bits := bits || ('renamed from ' || old.code); end if;
    if n_chg > 0 then bits := bits || (n_chg || ' changed'); end if;
    if n_add > 0 then bits := bits || (n_add || ' added'); end if;
    if n_rem > 0 then bits := bits || (n_rem || ' removed'); end if;
    if array_length(bits, 1) is null then
      return null;   -- only position / bookkeeping changed: nothing worth logging
    end if;
    info := jsonb_build_object('changed', n_chg, 'added', n_add, 'removed', n_rem,
                               'keys', keys, 'truncated', (n_chg + n_add + n_rem) > 200);
  end if;

  insert into public.activity_log (user_id, user_email, action, locale_id, locale_code, summary, details)
  values (auth.uid(), auth.jwt() ->> 'email', act, row_id, row_code, array_to_string(bits, ' · '), info);
  return null;
end;
$$;
revoke all on function public.locales_log() from public, anon, authenticated;

drop trigger if exists locales_log on public.locales;
create trigger locales_log
  after insert or update or delete on public.locales
  for each row execute function public.locales_log();
