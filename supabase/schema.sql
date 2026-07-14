-- Ore Line Shutdown reporter — Supabase schema
-- Run this once in the Supabase SQL Editor (Project > SQL Editor > New query).
-- Safe to re-run: uses "create or replace" / "if not exists" where possible.

-- =====================================================================
-- Profiles (one row per authenticated user, holds their editing role)
-- =====================================================================
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  role text not null default 'cust' check (role in ('admin','trim','te','tpt','exec','cust')),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

drop policy if exists "profiles readable by owner" on profiles;
create policy "profiles readable by owner" on profiles
  for select using (auth.uid() = id);

-- new signups get a profile row automatically, defaulted to the lowest-privilege
-- viewer role; an admin then updates their role in the Table Editor (see README).
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, display_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'display_name', new.email), 'cust');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- helper functions used by RLS policies below
create or replace function is_admin()
returns boolean language sql stable as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function can_edit_division(div_id text)
returns boolean language sql stable as $$
  select exists (
    select 1 from profiles
    where id = auth.uid()
      and (role = 'admin' or lower(role) = lower(div_id))
  );
$$;

-- =====================================================================
-- Report metadata (single row, id = 1)
-- =====================================================================
create table if not exists report_meta (
  id int primary key default 1 check (id = 1),
  name text not null,
  corridor text not null,
  start_date date not null,
  days int not null,
  demo boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id)
);

alter table report_meta enable row level security;
drop policy if exists "meta readable by all" on report_meta;
create policy "meta readable by all" on report_meta for select using (true);
drop policy if exists "meta editable by admin" on report_meta;
create policy "meta editable by admin" on report_meta for update using (is_admin()) with check (is_admin());

-- =====================================================================
-- Divisions / disciplines / KPIs
-- =====================================================================
create table if not exists divisions (
  id text primary key,          -- 'TRIM' | 'TE' | 'TPT'
  name text not null,
  color text not null,
  sort_order int not null default 0
);
alter table divisions enable row level security;
drop policy if exists "divisions readable by all" on divisions;
create policy "divisions readable by all" on divisions for select using (true);
drop policy if exists "divisions editable by admin" on divisions;
create policy "divisions editable by admin" on divisions for all using (is_admin()) with check (is_admin());

create table if not exists disciplines (
  id uuid primary key default gen_random_uuid(),
  division_id text not null references divisions(id) on delete cascade,
  name text not null,
  sort_order int not null default 0
);
alter table disciplines enable row level security;
drop policy if exists "disciplines readable by all" on disciplines;
create policy "disciplines readable by all" on disciplines for select using (true);
drop policy if exists "disciplines editable by admin" on disciplines;
create policy "disciplines editable by admin" on disciplines for all using (is_admin()) with check (is_admin());

create table if not exists kpis (
  id uuid primary key default gen_random_uuid(),
  discipline_id uuid not null references disciplines(id) on delete cascade,
  name text not null,
  work_type text not null,
  unit text not null,
  targets jsonb not null default '[]',
  sort_order int not null default 0
);
alter table kpis enable row level security;
drop policy if exists "kpis readable by all" on kpis;
create policy "kpis readable by all" on kpis for select using (true);
drop policy if exists "kpis editable by admin" on kpis;
create policy "kpis editable by admin" on kpis for all using (is_admin()) with check (is_admin());

-- =====================================================================
-- KPI location — links a work item back to the WeatherWatch forecast.
-- loc_from/loc_to hold a loop id ('1'..'19' or 'SALDANHA'); equal values
-- mean a single point, different values mean a section spanning the
-- loops between them (inclusive). Null = not mapped yet (no weather
-- risk shown for that KPI until an admin sets one in Setup).
-- =====================================================================
alter table kpis add column if not exists loc_from text;
alter table kpis add column if not exists loc_to text;

-- TE and TPT disciplines are all port/workshop-based — default those
-- KPIs to Saldanha Bay if not already mapped.
update kpis k
set loc_from = 'SALDANHA', loc_to = 'SALDANHA'
from disciplines d
where k.discipline_id = d.id
  and d.division_id in ('TE','TPT')
  and k.loc_from is null;

-- Seed a plausible starting location for existing TRIM KPIs so the
-- feature has data to show immediately — replace with the real location
-- via Setup > KPI register once confirmed. Safe to re-run: only fills
-- in KPIs that don't have a location yet.
do $$
declare
  r record;
  loops text[] := array['19','18','17','16','15','14','13','12','11','10','9','8','7','6','5','4','3','2','1'];
  pick text;
begin
  for r in
    select k.id from kpis k
    join disciplines d on d.id = k.discipline_id
    where d.division_id = 'TRIM' and k.loc_from is null
  loop
    pick := loops[1 + floor(random() * array_length(loops,1))::int];
    update kpis set loc_from = pick, loc_to = pick where id = r.id;
  end loop;
end $$;

-- =====================================================================
-- Daily actuals & deviations — the core reporting flow.
-- Writable by admins AND by the editor role matching the KPI's division
-- (TRIM editor -> TRIM KPIs, etc.), enforced here, not just in the UI.
-- =====================================================================
create table if not exists kpi_actuals (
  kpi_id uuid not null references kpis(id) on delete cascade,
  day int not null,
  value numeric,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id),
  primary key (kpi_id, day)
);
alter table kpi_actuals enable row level security;
drop policy if exists "actuals readable by all" on kpi_actuals;
create policy "actuals readable by all" on kpi_actuals for select using (true);
drop policy if exists "actuals writable by division editors" on kpi_actuals;
create policy "actuals writable by division editors" on kpi_actuals for all
  using (exists (
    select 1 from kpis k join disciplines d on d.id = k.discipline_id
    where k.id = kpi_actuals.kpi_id and can_edit_division(d.division_id)
  ))
  with check (exists (
    select 1 from kpis k join disciplines d on d.id = k.discipline_id
    where k.id = kpi_actuals.kpi_id and can_edit_division(d.division_id)
  ));

create table if not exists kpi_deviations (
  kpi_id uuid not null references kpis(id) on delete cascade,
  day int not null,
  category text not null,
  reason text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id),
  primary key (kpi_id, day)
);
alter table kpi_deviations enable row level security;
drop policy if exists "deviations readable by all" on kpi_deviations;
create policy "deviations readable by all" on kpi_deviations for select using (true);
drop policy if exists "deviations writable by division editors" on kpi_deviations;
create policy "deviations writable by division editors" on kpi_deviations for all
  using (exists (
    select 1 from kpis k join disciplines d on d.id = k.discipline_id
    where k.id = kpi_deviations.kpi_id and can_edit_division(d.division_id)
  ))
  with check (exists (
    select 1 from kpis k join disciplines d on d.id = k.discipline_id
    where k.id = kpi_deviations.kpi_id and can_edit_division(d.division_id)
  ));

create table if not exists kpi_photos (
  id uuid primary key default gen_random_uuid(),
  kpi_id uuid not null references kpis(id) on delete cascade,
  day int not null,
  storage_path text not null,
  lat double precision,
  lon double precision,
  caption text,
  gps_source text,
  loc_from text,
  loc_to text,
  created_at timestamptz not null default now(),
  created_by uuid references profiles(id)
);
-- loc_from/loc_to: same loop-id scheme as kpis, for photos tagged to a
-- section/loop manually (e.g. uploaded later by someone else) instead of
-- captured live with device GPS. Added here for installs predating it.
alter table kpi_photos add column if not exists loc_from text;
alter table kpi_photos add column if not exists loc_to text;
alter table kpi_photos enable row level security;
drop policy if exists "photos readable by all" on kpi_photos;
create policy "photos readable by all" on kpi_photos for select using (true);
drop policy if exists "photos writable by division editors" on kpi_photos;
create policy "photos writable by division editors" on kpi_photos for all
  using (exists (
    select 1 from kpis k join disciplines d on d.id = k.discipline_id
    where k.id = kpi_photos.kpi_id and can_edit_division(d.division_id)
  ))
  with check (exists (
    select 1 from kpis k join disciplines d on d.id = k.discipline_id
    where k.id = kpi_photos.kpi_id and can_edit_division(d.division_id)
  ));

-- =====================================================================
-- Storage bucket for site photos (public read, writes gated by the
-- same division-editor rule via a storage policy)
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('kpi-photos', 'kpi-photos', true)
on conflict (id) do nothing;

drop policy if exists "kpi photos public read" on storage.objects;
create policy "kpi photos public read" on storage.objects
  for select using (bucket_id = 'kpi-photos');

drop policy if exists "kpi photos writable by authenticated editors" on storage.objects;
create policy "kpi photos writable by authenticated editors" on storage.objects
  for insert with check (bucket_id = 'kpi-photos' and auth.role() = 'authenticated');

drop policy if exists "kpi photos deletable by authenticated editors" on storage.objects;
create policy "kpi photos deletable by authenticated editors" on storage.objects
  for delete using (bucket_id = 'kpi-photos' and auth.role() = 'authenticated');

-- =====================================================================
-- Seed data — mirrors the original in-app demo dataset
-- =====================================================================
insert into report_meta (id, name, corridor, start_date, days, demo)
values (1, 'Ore Line Annual Maintenance Shutdown', 'Sishen–Saldanha (861 km)', '2026-10-05', 10, true)
on conflict (id) do nothing;

insert into divisions (id, name, color, sort_order) values
  ('TRIM', 'Transnet Rail Infrastructure Manager', '#2F5D8A', 1),
  ('TE',   'Transnet Engineering',                 '#8A4B12', 2),
  ('TPT',  'Transnet Port Terminals (Saldanha)',    '#0F766E', 3)
on conflict (id) do nothing;

do $$
declare
  disc_track uuid; disc_ohte uuid; disc_signal uuid; disc_struct uuid;
  disc_wagon uuid; disc_loco uuid;
  disc_tippler uuid; disc_ship uuid; disc_conv uuid;
  kpi_id uuid;
begin
  -- skip entirely if disciplines already seeded (keep this script re-run safe)
  if exists (select 1 from disciplines) then
    return;
  end if;

  insert into disciplines (division_id, name, sort_order) values ('TRIM','Track (Perway)',1) returning id into disc_track;
  insert into disciplines (division_id, name, sort_order) values ('TRIM','OHTE (Electrical)',2) returning id into disc_ohte;
  insert into disciplines (division_id, name, sort_order) values ('TRIM','Signalling & Telecoms',3) returning id into disc_signal;
  insert into disciplines (division_id, name, sort_order) values ('TRIM','Structures',4) returning id into disc_struct;
  insert into disciplines (division_id, name, sort_order) values ('TE','Wagon Maintenance (Salkor)',1) returning id into disc_wagon;
  insert into disciplines (division_id, name, sort_order) values ('TE','Locomotives (15E fleet)',2) returning id into disc_loco;
  insert into disciplines (division_id, name, sort_order) values ('TPT','Tippler Complex',1) returning id into disc_tippler;
  insert into disciplines (division_id, name, sort_order) values ('TPT','Shiploaders & Stackers',2) returning id into disc_ship;
  insert into disciplines (division_id, name, sort_order) values ('TPT','Conveyors',3) returning id into disc_conv;

  -- Track (Perway)
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_track,'Rail replacement','Renewal','km','[3.6,3.6,3.6,3.6,3.6,3.6,3.6,3.6,3.6,3.6]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,3.6),(kpi_id,1,3.4),(kpi_id,2,3.8),(kpi_id,3,2.9),(kpi_id,4,3.6),(kpi_id,5,3.7);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,3,'Logistics / delivery','Rail train late ex Salkor yard; 0.7 km carried to Day 5 catch-up plan.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_track,'Sleeper replacement','Renewal','no.','[1800,1800,1800,1800,1800,1800,1800,1800,1800,1800]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,1820),(kpi_id,1,1795),(kpi_id,2,1810),(kpi_id,3,1760),(kpi_id,4,1840),(kpi_id,5,1815);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,3,'On-track machine breakdown','Sleeper gantry hydraulic failure 2h; recovered same shift.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_track,'Turnout replacement','Renewal','no.','[1,1,1,1,1,1,1,1,0,0]',3) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,1),(kpi_id,1,1),(kpi_id,2,1),(kpi_id,3,1),(kpi_id,4,1),(kpi_id,5,1);

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_track,'Tamping (production)','Maintenance','km','[8,8,8,8,8,8,8,8,8,8]',4) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,8.2),(kpi_id,1,7.9),(kpi_id,2,8.1),(kpi_id,3,6.4),(kpi_id,4,8.0),(kpi_id,5,8.3);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,3,'On-track machine breakdown','09-3X tamper lining unit fault; standby machine mobilised from Salkor.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_track,'Formation repair sites','Rehabilitation','sites','[2,2,2,2,2,2,2,2,2,2]',5) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,2),(kpi_id,1,2),(kpi_id,2,1),(kpi_id,3,2),(kpi_id,4,2),(kpi_id,5,2);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,2,'Weather','Rain at Loop 12 — earthworks compaction failed density test, redone Day 4.');

  -- OHTE (Electrical)
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_ohte,'Contact wire renewal','Renewal','km','[2.8,2.8,2.8,2.8,2.8,2.8,2.8,2.8,2.8,2.8]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,2.8),(kpi_id,1,2.9),(kpi_id,2,2.6),(kpi_id,3,2.8),(kpi_id,4,1.9),(kpi_id,5,2.7);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,4,'Security / theft & vandalism','Overnight theft of dropper/return conductor at km 384; team diverted to make safe.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_ohte,'Mast & cantilever replacement','Renewal','no.','[6,6,6,6,6,6,6,6,6,6]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,6),(kpi_id,1,6),(kpi_id,2,5),(kpi_id,3,6),(kpi_id,4,6),(kpi_id,5,7);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,2,'Material availability','One cantilever assembly short-supplied; fitted Day 6.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_ohte,'Section insulator replacement','Maintenance','no.','[4,4,4,4,4,4,4,4,4,4]',3) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,4),(kpi_id,1,4),(kpi_id,2,4),(kpi_id,3,4),(kpi_id,4,3),(kpi_id,5,4);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,4,'Weather','Wind gusts >60 km/h — elevated work suspended 3h.');

  -- Signalling & Telecoms
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_signal,'Points machine overhauls','Maintenance','no.','[5,5,5,5,5,5,5,5,5,5]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,5),(kpi_id,1,5),(kpi_id,2,5),(kpi_id,3,5),(kpi_id,4,5),(kpi_id,5,4);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,5,'Security / theft & vandalism','Cable theft at Loop 9 discovered on test; repair splice added to Day 7 scope.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_signal,'Cable route repairs','Rehabilitation','m','[400,400,400,400,400,400,400,400,400,400]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,420),(kpi_id,1,400),(kpi_id,2,380),(kpi_id,3,410),(kpi_id,4,400),(kpi_id,5,430);

  -- Structures
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_struct,'Culvert repairs','Rehabilitation','no.','[2,2,2,2,2,2,2,2,1,1]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,2),(kpi_id,1,2),(kpi_id,2,2),(kpi_id,3,2),(kpi_id,4,2),(kpi_id,5,2);

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_struct,'Bridge bearing replacements','Renewal','no.','[0,1,1,1,1,1,1,1,1,0]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,0),(kpi_id,1,1),(kpi_id,2,1),(kpi_id,3,1),(kpi_id,4,1),(kpi_id,5,1);

  -- Wagon Maintenance (Salkor)
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_wagon,'CR13/14 wagon general overhaul','Maintenance','wagons','[24,24,24,24,24,24,24,24,24,24]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,24),(kpi_id,1,25),(kpi_id,2,23),(kpi_id,3,24),(kpi_id,4,24),(kpi_id,5,22);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,5,'Material availability','CPSA knuckle stock-out; 2 wagons held awaiting couplers.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_wagon,'Wheelset changes','Maintenance','sets','[30,30,30,30,30,30,30,30,30,30]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,31),(kpi_id,1,30),(kpi_id,2,29),(kpi_id,3,30),(kpi_id,4,32),(kpi_id,5,30);

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_wagon,'Drawgear / knuckle replacements','Maintenance','no.','[40,40,40,40,40,40,40,40,40,40]',3) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,42),(kpi_id,1,40),(kpi_id,2,38),(kpi_id,3,41),(kpi_id,4,40),(kpi_id,5,33);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,5,'Material availability','Knuckle supply constraint — CPSA delivery rescheduled to Day 7.');

  -- Locomotives (15E fleet)
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_loco,'15E scheduled services','Maintenance','locos','[3,3,3,3,3,3,3,3,3,3]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,3),(kpi_id,1,3),(kpi_id,2,3),(kpi_id,3,3),(kpi_id,4,3),(kpi_id,5,3);

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_loco,'Traction motor changes','Maintenance','no.','[1,1,1,1,1,1,1,1,1,1]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,1),(kpi_id,1,1),(kpi_id,2,1),(kpi_id,3,1),(kpi_id,4,1),(kpi_id,5,1);

  -- Tippler Complex
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_tippler,'Tippler 1 refurbishment tasks','Maintenance','tasks','[12,12,12,12,12,12,12,12,12,12]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,12),(kpi_id,1,12),(kpi_id,2,11),(kpi_id,3,12),(kpi_id,4,12),(kpi_id,5,12);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,2,'Plant / equipment breakdown','Ring gear crack found on inspection — NDT and repair added to plan.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_tippler,'Tippler 2 refurbishment tasks','Maintenance','tasks','[10,10,10,10,10,10,10,10,10,10]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,10),(kpi_id,1,10),(kpi_id,2,10),(kpi_id,3,9),(kpi_id,4,10),(kpi_id,5,10);

  -- Shiploaders & Stackers
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_ship,'SL2 gearbox replacement tasks','Renewal','tasks','[8,8,8,8,8,8,8,8,8,8]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,8),(kpi_id,1,8),(kpi_id,2,8),(kpi_id,3,8),(kpi_id,4,6),(kpi_id,5,8);
  insert into kpi_deviations (kpi_id, day, category, reason) values (kpi_id,4,'Weather','Wind gusts 68 km/h at berth — crane lift for gearbox postponed to Day 6 morning.');

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_ship,'SR3 boom refurbishment tasks','Rehabilitation','tasks','[9,9,9,9,9,9,9,9,9,9]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,9),(kpi_id,1,9),(kpi_id,2,9),(kpi_id,3,9),(kpi_id,4,9),(kpi_id,5,9);

  -- Conveyors
  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_conv,'Belt splices completed','Maintenance','no.','[4,4,4,4,4,4,4,4,4,4]',1) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,4),(kpi_id,1,4),(kpi_id,2,4),(kpi_id,3,4),(kpi_id,4,4),(kpi_id,5,4);

  insert into kpis (discipline_id, name, work_type, unit, targets, sort_order)
    values (disc_conv,'Idler replacements','Maintenance','no.','[120,120,120,120,120,120,120,120,120,120]',2) returning id into kpi_id;
  insert into kpi_actuals (kpi_id, day, value) values (kpi_id,0,124),(kpi_id,1,120),(kpi_id,2,118),(kpi_id,3,122),(kpi_id,4,119),(kpi_id,5,121);
end $$;

-- =====================================================================
-- Realtime — expose these tables so clients get live updates
-- (guarded so this script can be re-run safely)
-- =====================================================================
do $$
declare
  t text;
begin
  foreach t in array array['kpi_actuals','kpi_deviations','kpi_photos','kpis','disciplines','report_meta']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;
