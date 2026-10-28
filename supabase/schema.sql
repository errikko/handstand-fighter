-- Handstand Fighter: profiles, signup trigger, referral stats.
-- Run once in Supabase Dashboard -> SQL Editor.

create table public.profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  nickname           text check (char_length(nickname) between 1 and 24),
  total_reps         integer not null default 0 check (total_reps >= 0),
  total_hold_seconds integer not null default 0 check (total_hold_seconds >= 0),
  best_reps_value    integer check (best_reps_value >= 0),
  best_reps_at       timestamptz,
  best_hold_value    integer check (best_hold_value >= 0),
  best_hold_at       timestamptz,
  referred_by        text,
  has_access         boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index profiles_referred_by_idx on public.profiles (referred_by);

alter table public.profiles enable row level security;

create policy "Users read own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Users update own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Rows are created only by the signup trigger. Clients may update progress
-- columns, but never has_access or referred_by.
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (
  nickname, total_reps, total_hold_seconds,
  best_reps_value, best_reps_at, best_hold_value, best_hold_at, updated_at
) on public.profiles to authenticated;

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  ref text := lower(nullif(trim(new.raw_user_meta_data ->> 'referred_by'), ''));
begin
  if ref is not null and ref !~ '^[a-z0-9_-]{1,64}$' then
    ref := null;
  end if;
  insert into public.profiles (id, referred_by) values (new.id, ref);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Signups per referral code. Readable from the dashboard only.
create view public.referral_stats
with (security_invoker = true) as
  select referred_by       as code,
         count(*)          as signups,
         min(created_at)   as first_signup,
         max(created_at)   as last_signup
  from public.profiles
  where referred_by is not null
  group by referred_by
  order by signups desc;

revoke all on public.referral_stats from anon, authenticated;
