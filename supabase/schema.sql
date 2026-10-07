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
