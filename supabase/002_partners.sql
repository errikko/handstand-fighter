-- Handstand Fighter: partner program (one level, manual payments and payouts).
-- Run once in Supabase Dashboard -> SQL Editor, after schema.sql.

-- Short, unambiguous personal codes (no 0/o/1/l/i)
create function public.gen_ref_code()
returns text
language plpgsql
set search_path = ''
as $$
declare
  chars text := 'abcdefghjkmnpqrstuvwxyz23456789';
  code text;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where ref_code = code);
  end loop;
  return code;
end;
$$;
revoke execute on function public.gen_ref_code() from public, anon, authenticated;

alter table public.profiles
  add column ref_code text unique,
  add column commission_rate numeric(4,3) not null default 0.200
    check (commission_rate >= 0 and commission_rate <= 1);

update public.profiles set ref_code = public.gen_ref_code() where ref_code is null;
alter table public.profiles alter column ref_code set not null;

-- New signups get a personal code alongside the referral they arrived with
create or replace function public.handle_new_user()
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
  insert into public.profiles (id, referred_by, ref_code)
  values (new.id, ref, public.gen_ref_code());
  return new;
end;
$$;

-- Payments you record by hand. Only user_id and amount are needed;
-- partner_id and commission are filled in automatically.
create table public.payments (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles (id) on delete restrict,
  amount      numeric(12,2) not null check (amount > 0),
  currency    text not null default 'RUB',
  paid_at     timestamptz not null default now(),
  note        text,
  partner_id  uuid references public.profiles (id) on delete set null,
  commission  numeric(12,2) not null default 0
);
create index payments_partner_idx on public.payments (partner_id);

-- Payouts you send to partners by hand
create table public.payouts (
  id          bigint generated always as identity primary key,
  partner_id  uuid not null references public.profiles (id) on delete restrict,
  amount      numeric(12,2) not null check (amount > 0),
  currency    text not null default 'RUB',
  paid_at     timestamptz not null default now(),
  note        text
);
create index payouts_partner_idx on public.payouts (partner_id);

alter table public.payments enable row level security;
alter table public.payouts enable row level security;
revoke all on public.payments from anon, authenticated;
revoke all on public.payouts from anon, authenticated;

-- Snapshot the partner and their rate at payment time, so later rate changes
-- don't rewrite past earnings
create function public.payments_assign_partner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  partner record;
begin
  select pr.id, pr.commission_rate into partner
  from public.profiles payer
  join public.profiles pr on pr.ref_code = payer.referred_by
  where payer.id = new.user_id and pr.id <> new.user_id;

  if found then
    new.partner_id := partner.id;
    new.commission := round(new.amount * partner.commission_rate, 2);
  else
    new.partner_id := null;
    new.commission := 0;
  end if;
  return new;
end;
$$;
revoke execute on function public.payments_assign_partner() from public, anon, authenticated;

create trigger payments_assign_partner
  before insert on public.payments
  for each row execute function public.payments_assign_partner();

-- Per-partner totals. Readable from the dashboard only.
create view public.partner_earnings
with (security_invoker = true) as
  select p.id                as partner_id,
         p.nickname,
         p.ref_code,
         p.commission_rate,
         coalesce(inv.invited, 0)  as invited,
         coalesce(pay.paying, 0)   as paying,
         coalesce(pay.revenue, 0)  as revenue,
         coalesce(pay.earned, 0)   as earned,
         coalesce(po.paid_out, 0)  as paid_out,
         coalesce(pay.earned, 0) - coalesce(po.paid_out, 0) as balance
  from public.profiles p
  left join (select referred_by, count(*) as invited from public.profiles group by referred_by) inv
    on inv.referred_by = p.ref_code
  left join (select partner_id, count(distinct user_id) as paying, sum(amount) as revenue, sum(commission) as earned
             from public.payments group by partner_id) pay
    on pay.partner_id = p.id
  left join (select partner_id, sum(amount) as paid_out from public.payouts group by partner_id) po
    on po.partner_id = p.id
  where coalesce(inv.invited, 0) > 0 or coalesce(pay.earned, 0) > 0 or coalesce(po.paid_out, 0) > 0
  order by balance desc, invited desc;
revoke all on public.partner_earnings from anon, authenticated;

-- What a signed-in user may see about their own partner account: counts and sums, no names
create function public.get_my_partner_stats()
returns json
language sql
stable
security definer
set search_path = ''
as $$
  select json_build_object(
    'ref_code',        p.ref_code,
    'commission_rate', p.commission_rate,
    'invited',  (select count(*) from public.profiles r where r.referred_by = p.ref_code),
    'paying',   (select count(distinct pay.user_id) from public.payments pay where pay.partner_id = p.id),
    'earned',   coalesce((select sum(pay.commission) from public.payments pay where pay.partner_id = p.id), 0),
    'paid_out', coalesce((select sum(po.amount) from public.payouts po where po.partner_id = p.id), 0),
    'referrer', (select r.nickname from public.profiles r where r.ref_code = p.referred_by and r.id <> p.id)
  )
  from public.profiles p
  where p.id = auth.uid();
$$;
revoke execute on function public.get_my_partner_stats() from public, anon;
grant execute on function public.get_my_partner_stats() to authenticated;
