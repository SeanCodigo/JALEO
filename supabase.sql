-- =====================================================================
-- JALEO Club · base de dades (Supabase / PostgreSQL)
-- Enganxa tot aquest fitxer a Supabase > SQL Editor > New query > Run.
-- Es pot tornar a executar: no esborra dades si les taules ja existeixen.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- REGLES DEL PROGRAMA (canvia-les aquí si cal) ----------
create or replace function public.rules() returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'welcome_points', 10,   -- punts en crear la targeta
    'ref_points', 10,       -- punts per a cadascú quan un amic convidat gasta el mínim
    'ref_min_spend', 10,    -- euros que ha de gastar l'amic
    'max_points_visit', 50  -- màxim de punts per comanda o cobrament
  )
$$;

-- ---------- TAULES ----------
create table if not exists public.menu_items (
  id serial primary key,
  category text not null,
  name text not null,
  price numeric(6,2) not null check (price >= 0),
  icon text not null default 'glass',
  color text not null default '#A3202F',
  active boolean not null default true,
  sort int not null default 0
);

create table if not exists public.rewards (
  id serial primary key,
  name text not null,
  cost int not null check (cost > 0),
  active boolean not null default true
);

create table if not exists public.offers (
  id serial primary key,
  title text not null,
  body text not null default '',
  active boolean not null default true
);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  secret text unique not null,
  name text not null,
  email text unique not null,
  marketing boolean not null default false,
  points int not null default 0,
  visits int not null default 0,
  spent numeric(10,2) not null default 0,
  last_visit timestamptz,
  referred_by uuid references public.customers(id),
  ref_bonus_done boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id bigserial primary key,
  table_no text not null,
  customer_id uuid references public.customers(id),
  items jsonb not null,
  total numeric(10,2) not null,
  status text not null default 'rebuda'
    check (status in ('rebuda','preparant','servida','pagada','cancelada')),
  points_awarded int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.reward_requests (
  id bigserial primary key,
  customer_id uuid not null references public.customers(id),
  reward_id int references public.rewards(id),
  reward_name text not null,
  cost int not null,
  table_no text,
  status text not null default 'pendent'
    check (status in ('pendent','entregat','rebutjat')),
  created_at timestamptz not null default now()
);

create table if not exists public.dining_tables (
  id serial primary key,
  name text not null,
  seats int not null default 4,
  shape text not null default 'round' check (shape in ('round','rect','sofa','bar')),
  x numeric not null default 10,   -- posició en % de l'amplada del plànol
  y numeric not null default 10,   -- posició en % de l'alçada del plànol
  w numeric not null default 10,   -- amplada en %
  h numeric not null default 12,   -- alçada en %
  bookable boolean not null default true
);

create table if not exists public.reservations (
  id bigserial primary key,
  customer_id uuid not null references public.customers(id),
  table_id int references public.dining_tables(id),
  day date not null,
  time text not null,
  people int not null check (people between 1 and 40),
  note text,
  status text not null default 'pendent'
    check (status in ('pendent','confirmada','rebutjada')),
  created_at timestamptz not null default now()
);

alter table public.reservations add column if not exists table_id int references public.dining_tables(id);

create table if not exists public.notices (
  id bigserial primary key,
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.points_log (
  id bigserial primary key,
  customer_id uuid not null references public.customers(id),
  delta int not null,
  reason text not null,
  created_at timestamptz not null default now()
);

-- ---------- SEGURETAT (RLS) ----------
-- El personal (usuaris amb sessió iniciada) ho pot veure i editar tot.
-- El públic només pot llegir la carta, les recompenses, les ofertes i els avisos.
-- Tota la resta el públic ho fa a través de les funcions de més avall.
do $$
declare t text;
begin
  foreach t in array array['menu_items','rewards','offers','customers','orders','dining_tables',
                           'reward_requests','reservations','notices','points_log']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists staff_all on public.%I', t);
    execute format('create policy staff_all on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

drop policy if exists public_read on public.menu_items;
create policy public_read on public.menu_items for select to anon using (active);
drop policy if exists public_read on public.rewards;
create policy public_read on public.rewards for select to anon using (active);
drop policy if exists public_read on public.offers;
create policy public_read on public.offers for select to anon using (active);
drop policy if exists public_read on public.dining_tables;
create policy public_read on public.dining_tables for select to anon using (true);
drop policy if exists public_read on public.notices;
create policy public_read on public.notices for select to anon using (true);

-- ---------- FUNCIONS INTERNES ----------
create or replace function public.new_code() returns text
language plpgsql set search_path = public, extensions as $$
declare c text;
begin
  loop
    c := 'J' || upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.customers where code = c);
  end loop;
  return c;
end $$;

-- Suma punts per una despesa i aplica el bonus d'amic si toca. Retorna els punts sumats.
create or replace function public.award_spend(p_customer uuid, p_amount numeric, p_reason text)
returns int language plpgsql security definer set search_path = public as $$
declare
  r jsonb := public.rules();
  c public.customers;
  pts int;
begin
  select * into c from public.customers where id = p_customer for update;
  if not found then return 0; end if;
  pts := least((r->>'max_points_visit')::int, floor(greatest(p_amount, 0))::int);
  update public.customers
     set points = points + pts, visits = visits + 1, spent = spent + p_amount, last_visit = now()
   where id = c.id;
  insert into public.points_log(customer_id, delta, reason) values (c.id, pts, p_reason);
  if c.referred_by is not null and not c.ref_bonus_done
     and c.spent + p_amount >= (r->>'ref_min_spend')::numeric then
    update public.customers set points = points + (r->>'ref_points')::int, ref_bonus_done = true where id = c.id;
    update public.customers set points = points + (r->>'ref_points')::int where id = c.referred_by;
    insert into public.points_log(customer_id, delta, reason) values
      (c.id, (r->>'ref_points')::int, 'Bonus amic'),
      (c.referred_by, (r->>'ref_points')::int, 'Bonus amic convidat');
  end if;
  return pts;
end $$;
revoke execute on function public.award_spend(uuid, numeric, text) from public, anon, authenticated;

-- ---------- FUNCIONS PER AL CLIENT (públiques) ----------
create or replace function public.create_card(p_name text, p_email text, p_marketing boolean,
                                              p_adult boolean, p_ref text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb := public.rules();
  v_ref uuid;
  v_code text;
  v_secret text;
  v_email text := lower(trim(p_email));
  v_id uuid;
begin
  if not coalesce(p_adult, false) then raise exception 'ADULT_REQUIRED'; end if;
  if length(trim(coalesce(p_name,''))) < 1 or length(p_name) > 60 then raise exception 'BAD_NAME'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'BAD_EMAIL'; end if;
  if exists (select 1 from public.customers where email = v_email) then raise exception 'EMAIL_EXISTS'; end if;
  if p_ref is not null and p_ref <> '' then
    select id into v_ref from public.customers where code = upper(p_ref);
  end if;
  v_code := public.new_code();
  v_secret := encode(extensions.gen_random_bytes(18), 'hex');
  insert into public.customers(code, secret, name, email, marketing, points, referred_by)
  values (v_code, v_secret, trim(p_name), v_email, coalesce(p_marketing,false), (r->>'welcome_points')::int, v_ref)
  returning id into v_id;
  insert into public.points_log(customer_id, delta, reason) values (v_id, (r->>'welcome_points')::int, 'Benvinguda');
  return jsonb_build_object('code', v_code, 'secret', v_secret);
end $$;

create or replace function public.get_card(p_secret text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.customers;
begin
  select * into c from public.customers where secret = p_secret;
  if not found then return null; end if;
  return jsonb_build_object(
    'code', c.code, 'name', c.name, 'points', c.points, 'visits', c.visits,
    'rules', public.rules(),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'reward_id', q.reward_id,
                  'reward_name', q.reward_name, 'status', q.status, 'created_at', q.created_at)
                  order by q.created_at desc)
                  from (select * from public.reward_requests where customer_id = c.id
                        order by created_at desc limit 10) q), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('day', x.day, 'time', x.time,
                  'table', (select name from public.dining_tables t where t.id = x.table_id),
                  'people', x.people, 'status', x.status) order by x.day desc)
                  from (select * from public.reservations where customer_id = c.id
                        order by created_at desc limit 5) x), '[]'::jsonb)
  );
end $$;

create or replace function public.place_order(p_table text, p_items jsonb, p_secret text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_items jsonb := '[]'::jsonb;
  v_total numeric := 0;
  e record;
  m public.menu_items;
  v_cust uuid;
  v_id bigint;
begin
  if p_table is null or length(p_table) = 0 or length(p_table) > 10 then raise exception 'BAD_TABLE'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 30 then
    raise exception 'BAD_ITEMS';
  end if;
  if (select count(*) from public.orders where table_no = p_table and created_at > now() - interval '5 minutes') >= 5 then
    raise exception 'TOO_MANY';
  end if;
  for e in select (x->>'id')::int as id, (x->>'qty')::int as qty from jsonb_array_elements(p_items) x loop
    if e.qty is null or e.qty < 1 or e.qty > 20 then raise exception 'BAD_QTY'; end if;
    select * into m from public.menu_items where id = e.id and active;
    if not found then raise exception 'BAD_ITEM'; end if;
    v_items := v_items || jsonb_build_object('name', m.name, 'qty', e.qty, 'price', m.price);
    v_total := v_total + m.price * e.qty;
  end loop;
  if p_secret is not null and p_secret <> '' then
    select id into v_cust from public.customers where secret = p_secret;
  end if;
  insert into public.orders(table_no, customer_id, items, total)
  values (p_table, v_cust, v_items, v_total) returning id into v_id;
  return v_id;
end $$;

create or replace function public.get_order(p_id bigint, p_table text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'status', o.status, 'items', o.items, 'total', o.total,
                            'points_awarded', o.points_awarded)
  from public.orders o where o.id = p_id and o.table_no = p_table
$$;

create or replace function public.request_reward(p_secret text, p_reward_id int, p_table text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare c public.customers; w public.rewards; v_id bigint;
begin
  select * into c from public.customers where secret = p_secret;
  if not found then raise exception 'NO_CARD'; end if;
  select * into w from public.rewards where id = p_reward_id and active;
  if not found then raise exception 'NO_REWARD'; end if;
  if c.points < w.cost then raise exception 'NOT_ENOUGH'; end if;
  if exists (select 1 from public.reward_requests where customer_id = c.id and status = 'pendent') then
    raise exception 'ALREADY_PENDING';
  end if;
  insert into public.reward_requests(customer_id, reward_id, reward_name, cost, table_no)
  values (c.id, w.id, w.name, w.cost, nullif(p_table,'')) returning id into v_id;
  return v_id;
end $$;

-- Taules ja reservades un dia (perquè el client vegi què queda lliure al mapa)
create or replace function public.taken_tables(p_day date)
returns int[] language sql security definer set search_path = public as $$
  select coalesce(array_agg(distinct table_id), '{}') from public.reservations
  where day = p_day and table_id is not null and status in ('pendent','confirmada')
$$;

drop function if exists public.create_reservation(text, date, text, int, text);
create or replace function public.create_reservation(p_secret text, p_day date, p_time text,
                                                     p_people int, p_note text default null,
                                                     p_table_id int default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare c public.customers; v_id bigint;
begin
  select * into c from public.customers where secret = p_secret;
  if not found then raise exception 'NO_CARD'; end if;
  if p_day < current_date or p_day > current_date + 60 then raise exception 'BAD_DAY'; end if;
  if p_people < 1 or p_people > 40 then raise exception 'BAD_PEOPLE'; end if;
  if (select count(*) from public.reservations where customer_id = c.id and status = 'pendent') >= 3 then
    raise exception 'TOO_MANY';
  end if;
  if p_table_id is not null then
    if not exists (select 1 from public.dining_tables where id = p_table_id and bookable) then
      raise exception 'BAD_TABLE';
    end if;
    if p_table_id = any(public.taken_tables(p_day)) then raise exception 'TABLE_TAKEN'; end if;
  end if;
  insert into public.reservations(customer_id, table_id, day, time, people, note)
  values (c.id, p_table_id, p_day, left(p_time, 10), p_people, left(p_note, 300)) returning id into v_id;
  return v_id;
end $$;

-- ---------- FUNCIONS PER AL PERSONAL (cal sessió iniciada) ----------
create or replace function public.pay_order(p_id bigint)
returns int language plpgsql security definer set search_path = public as $$
declare o public.orders; pts int := 0;
begin
  if auth.uid() is null then raise exception 'STAFF_ONLY'; end if;
  select * into o from public.orders where id = p_id for update;
  if not found or o.status in ('pagada','cancelada') then return 0; end if;
  if o.customer_id is not null then
    pts := public.award_spend(o.customer_id, o.total, 'Comanda #' || o.id);
  end if;
  update public.orders set status = 'pagada', points_awarded = pts where id = p_id;
  return pts;
end $$;

create or replace function public.add_points(p_code text, p_amount numeric)
returns int language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then raise exception 'STAFF_ONLY'; end if;
  if p_amount <= 0 or p_amount > 500 then raise exception 'BAD_AMOUNT'; end if;
  select id into v from public.customers where code = upper(trim(p_code));
  if not found then raise exception 'NO_CARD'; end if;
  return public.award_spend(v, p_amount, 'Cobrament a la barra');
end $$;

create or replace function public.resolve_reward(p_id bigint, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare q public.reward_requests; c public.customers;
begin
  if auth.uid() is null then raise exception 'STAFF_ONLY'; end if;
  select * into q from public.reward_requests where id = p_id for update;
  if not found or q.status <> 'pendent' then return 'ja resolt'; end if;
  if not p_accept then
    update public.reward_requests set status = 'rebutjat' where id = p_id;
    return 'rebutjat';
  end if;
  select * into c from public.customers where id = q.customer_id for update;
  if c.points < q.cost then
    update public.reward_requests set status = 'rebutjat' where id = p_id;
    return 'sense punts';
  end if;
  update public.customers set points = points - q.cost where id = c.id;
  insert into public.points_log(customer_id, delta, reason) values (c.id, -q.cost, 'Premi: ' || q.reward_name);
  update public.reward_requests set status = 'entregat' where id = p_id;
  return 'entregat';
end $$;

revoke execute on function public.pay_order(bigint) from public, anon;
revoke execute on function public.add_points(text, numeric) from public, anon;
revoke execute on function public.resolve_reward(bigint, boolean) from public, anon;
grant execute on function public.pay_order(bigint) to authenticated;
grant execute on function public.add_points(text, numeric) to authenticated;
grant execute on function public.resolve_reward(bigint, boolean) to authenticated;

-- ---------- AVISOS EN DIRECTE PER AL PANELL ----------
do $$
begin
  begin alter publication supabase_realtime add table public.orders; exception when others then null; end;
  begin alter publication supabase_realtime add table public.reward_requests; exception when others then null; end;
  begin alter publication supabase_realtime add table public.reservations; exception when others then null; end;
end $$;

-- ---------- DADES INICIALS (només si les taules són buides) ----------
insert into public.menu_items(category, name, price, icon, color, sort)
select * from (values
  ('Copes','Cubata',7.00,'glass','#7A3412',1),
  ('Copes','Cubata premium',10.00,'glass','#5a2208',2),
  ('Copes','Mojito',7.00,'cocktail','#4f8a3c',3),
  ('Copes','Piña colada',7.50,'cocktail','#c9a55a',4),
  ('Copes','Margarita',9.00,'cocktail','#9bbf4a',5),
  ('Cervesa','Canya',2.30,'beer','#d49a2a',10),
  ('Cervesa','Mitjana',2.80,'beer','#c98a1f',11),
  ('Cervesa','Galleda 6 quintos',10.00,'bucket','#b8954e',12),
  ('Cervesa','Galleda 10 quintos',15.00,'bucket','#a88a45',13),
  ('Xupitos','Xupito',2.00,'shot','#B0232F',20),
  ('Cachimbes','Cachimba',12.00,'hookah','#7A1424',30),
  ('Cachimbes','Cachimba premium',18.00,'hookah','#C9A55A',31),
  ('Sense alcohol','Refresc',2.50,'soda','#3e6db5',40),
  ('Sense alcohol','Red Bull',3.50,'soda','#2b5aa0',41),
  ('Sense alcohol','Aigua',1.50,'soda','#7fa9cf',42)
) v where not exists (select 1 from public.menu_items);

insert into public.rewards(name, cost)
select * from (values ('Refresc o xupito', 30), ('Cubata de regal', 60), ('Cachimba sense nicotina de regal', 120)) v
where not exists (select 1 from public.rewards);

insert into public.offers(title, body)
select * from (values ('Doble punts els dijous', 'Jaleo Universitari · per a membres JCC'),
                      ('Oferta de membres', 'Canvia aquest text des del panell')) v
where not exists (select 1 from public.offers);

-- Plànol inicial aproximat (mou les taules des del panell > Plànol)
insert into public.dining_tables(name, seats, shape, x, y, w, h, bookable)
select * from (values
  ('Barra', 0, 'bar', 3, 8, 12, 70, false),
  ('Taula 1', 4, 'round', 22, 10, 10, 14, true),
  ('Taula 2', 6, 'sofa', 38, 4, 24, 14, true),
  ('Taula 3', 5, 'sofa', 68, 4, 22, 14, true),
  ('Taula 4', 4, 'rect', 72, 30, 18, 14, true),
  ('Taula 5', 3, 'round', 24, 36, 8, 11, true),
  ('Taula 6', 3, 'round', 38, 36, 8, 11, true),
  ('Taula 7', 6, 'sofa', 52, 56, 16, 16, true),
  ('Taula 8', 4, 'sofa', 74, 58, 16, 16, true),
  ('Taula 9', 7, 'round', 24, 62, 14, 20, true)
) v(name, seats, shape, x, y, w, h, bookable) where not exists (select 1 from public.dining_tables);

-- ---------- PERMISOS DE L'API (Supabase no els dona per defecte als projectes nous) ----------
grant usage on schema public to anon, authenticated;
grant select on public.menu_items, public.rewards, public.offers, public.dining_tables, public.notices to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.rules() to anon, authenticated;
grant execute on function public.create_card(text, text, boolean, boolean, text) to anon, authenticated;
grant execute on function public.get_card(text) to anon, authenticated;
grant execute on function public.place_order(text, jsonb, text) to anon, authenticated;
grant execute on function public.get_order(bigint, text) to anon, authenticated;
grant execute on function public.request_reward(text, int, text) to anon, authenticated;
grant execute on function public.taken_tables(date) to anon, authenticated;
grant execute on function public.create_reservation(text, date, text, int, text, int) to anon, authenticated;
revoke execute on function public.new_code() from public, anon, authenticated;

-- ---------- NOMÉS EL PERSONAL DE LA LLISTA POT ENTRAR AL PANELL ----------
-- Per afegir algú: insert into public.staff(email) values ('email@exemple.com');
create table if not exists public.staff (
  email text primary key,
  created_at timestamptz not null default now()
);
alter table public.staff enable row level security;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;
revoke execute on function public.is_staff() from public, anon;
grant execute on function public.is_staff() to authenticated;

do $$
declare t text;
begin
  foreach t in array array['menu_items','rewards','offers','customers','orders','dining_tables',
                           'reward_requests','reservations','notices','points_log']
  loop
    execute format('drop policy if exists staff_all on public.%I', t);
    execute format('create policy staff_all on public.%I for all to authenticated using (public.is_staff()) with check (public.is_staff())', t);
  end loop;
end $$;
drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());
revoke insert, update, delete on public.staff from authenticated, anon;

create or replace function public.pay_order(p_id bigint)
returns int language plpgsql security definer set search_path = public as $$
declare o public.orders; pts int := 0;
begin
  if not public.is_staff() then raise exception 'STAFF_ONLY'; end if;
  select * into o from public.orders where id = p_id for update;
  if not found or o.status in ('pagada','cancelada') then return 0; end if;
  if o.customer_id is not null then
    pts := public.award_spend(o.customer_id, o.total, 'Comanda #' || o.id);
  end if;
  update public.orders set status = 'pagada', points_awarded = pts where id = p_id;
  return pts;
end $$;

create or replace function public.add_points(p_code text, p_amount numeric)
returns int language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not public.is_staff() then raise exception 'STAFF_ONLY'; end if;
  if p_amount <= 0 or p_amount > 500 then raise exception 'BAD_AMOUNT'; end if;
  select id into v from public.customers where code = upper(trim(p_code));
  if not found then raise exception 'NO_CARD'; end if;
  return public.award_spend(v, p_amount, 'Cobrament a la barra');
end $$;

create or replace function public.resolve_reward(p_id bigint, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare q public.reward_requests; c public.customers;
begin
  if not public.is_staff() then raise exception 'STAFF_ONLY'; end if;
  select * into q from public.reward_requests where id = p_id for update;
  if not found or q.status <> 'pendent' then return 'ja resolt'; end if;
  if not p_accept then
    update public.reward_requests set status = 'rebutjat' where id = p_id;
    return 'rebutjat';
  end if;
  select * into c from public.customers where id = q.customer_id for update;
  if c.points < q.cost then
    update public.reward_requests set status = 'rebutjat' where id = p_id;
    return 'sense punts';
  end if;
  update public.customers set points = points - q.cost where id = c.id;
  insert into public.points_log(customer_id, delta, reason) values (c.id, -q.cost, 'Premi: ' || q.reward_name);
  update public.reward_requests set status = 'entregat' where id = p_id;
  return 'entregat';
end $$;

revoke execute on function public.pay_order(bigint) from public, anon;
revoke execute on function public.add_points(text, numeric) from public, anon;
revoke execute on function public.resolve_reward(bigint, boolean) from public, anon;
grant execute on function public.pay_order(bigint) to authenticated;
grant execute on function public.add_points(text, numeric) to authenticated;
grant execute on function public.resolve_reward(bigint, boolean) to authenticated;

-- ---------- FOTOS DELS PRODUCTES ----------
alter table public.menu_items add column if not exists image text;
update public.menu_items set image = 'img/productes/' || v.slug || '.svg'
from (values
  ('Cubata','cubata'),('Cubata premium','cubata-premium'),('Mojito','mojito'),('Piña colada','pina-colada'),
  ('Margarita','margarita'),('Canya','canya'),('Mitjana','mitjana'),('Galleda 6 quintos','galleda-6-quintos'),
  ('Galleda 10 quintos','galleda-10-quintos'),('Xupito','xupito'),('Cachimba','cachimba'),
  ('Cachimba premium','cachimba-premium'),('Refresc','refresc'),('Red Bull','red-bull'),('Aigua','aigua')
) as v(name, slug)
where public.menu_items.name = v.name and public.menu_items.image is null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('productes', 'productes', true, 5242880, array['image/jpeg','image/png','image/webp','image/svg+xml'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists productes_staff_insert on storage.objects;
create policy productes_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'productes' and public.is_staff());
drop policy if exists productes_staff_update on storage.objects;
create policy productes_staff_update on storage.objects for update to authenticated
  using (bucket_id = 'productes' and public.is_staff()) with check (bucket_id = 'productes' and public.is_staff());
drop policy if exists productes_staff_delete on storage.objects;
create policy productes_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'productes' and public.is_staff());

-- =====================================================================
-- NOTIFICACIONS AL MÒBIL (Web Push)
-- Les claus VAPID es guarden a public.app_secrets (vapid_public, vapid_private),
-- sense accés per a anon/authenticated. Les fa servir la funció Edge «send-push».
-- =====================================================================
create table if not exists public.push_subs (
  id bigint generated always as identity primary key,
  endpoint text unique not null,
  p256dh text not null,
  auth text not null,
  customer_id uuid references public.customers(id) on delete set null,
  created_at timestamptz default now(),
  last_ok timestamptz
);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;
grant select, delete on public.push_subs to authenticated;
drop policy if exists staff_all on public.push_subs;
create policy staff_all on public.push_subs for all to authenticated using (public.is_staff()) with check (public.is_staff());

create table if not exists public.app_secrets (k text primary key, v text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

create or replace function public.save_push(p_endpoint text, p_p256dh text, p_auth text, p_secret text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or length(coalesce(p_p256dh,'')) not between 40 and 200 or length(coalesce(p_auth,'')) not between 10 and 100 then
    raise exception 'subscripcio no valida';
  end if;
  if p_secret is not null then select id into cid from customers where secret = p_secret; end if;
  insert into push_subs(endpoint, p256dh, auth, customer_id) values (p_endpoint, p_p256dh, p_auth, cid)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, customer_id = coalesce(excluded.customer_id, push_subs.customer_id);
  return true;
end $$;

create or replace function public.drop_push(p_endpoint text)
returns boolean language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = p_endpoint; select true;
$$;
revoke all on function public.save_push(text,text,text,text), public.drop_push(text) from public;
grant execute on function public.save_push(text,text,text,text), public.drop_push(text) to anon, authenticated;

-- =====================================================================
-- RECUPERAR LA TARGETA: mateix email + mateix nom = es torna la targeta existent
-- (versió actualitzada de create_card aplicada a Supabase)
-- =====================================================================
create or replace function public.create_card(p_name text, p_email text, p_marketing boolean,
                                              p_adult boolean, p_ref text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb := public.rules();
  v_ref uuid; v_code text; v_secret text; v_id uuid;
  v_email text := lower(trim(p_email));
  ex public.customers;
begin
  if not coalesce(p_adult, false) then raise exception 'ADULT_REQUIRED'; end if;
  if length(trim(coalesce(p_name,''))) < 1 or length(p_name) > 60 then raise exception 'BAD_NAME'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 120 then raise exception 'BAD_EMAIL'; end if;
  select * into ex from public.customers where email = v_email;
  if found then
    if lower(regexp_replace(trim(ex.name), '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g')) then
      if coalesce(p_marketing, false) and not ex.marketing then update public.customers set marketing = true where id = ex.id; end if;
      return jsonb_build_object('code', ex.code, 'secret', ex.secret, 'existing', true);
    end if;
    raise exception 'EMAIL_EXISTS';
  end if;
  if p_ref is not null and p_ref <> '' then select id into v_ref from public.customers where code = upper(p_ref); end if;
  v_code := public.new_code();
  v_secret := encode(extensions.gen_random_bytes(18), 'hex');
  insert into public.customers(code, secret, name, email, marketing, points, referred_by)
  values (v_code, v_secret, trim(p_name), v_email, coalesce(p_marketing,false), (r->>'welcome_points')::int, v_ref)
  returning id into v_id;
  insert into public.points_log(customer_id, delta, reason) values (v_id, (r->>'welcome_points')::int, 'Benvinguda');
  return jsonb_build_object('code', v_code, 'secret', v_secret, 'existing', false);
end $$;

-- =====================================================================
-- JCC, OFERTES DE MEMBRES I NOTIFICACIONS AUTOMÀTIQUES
-- Aplicat a Supabase amb les migracions: jaleo_push_trigger, jaleo_service_role_grants,
-- jaleo_jcc_and_member_offers i jaleo_fix_join_jcc (Supabase → Database → Migrations).
--  · customers.jcc / jcc_since · join_jcc(secret, codi) · jcc_code() · new_jcc_code()
--  · award_spend(): punts x2 els dijous (dia de servei fins a les 6 h) per als JCC
--  · offers: emoji, perk, days int[] (1=dl … 7=dg), from_time, claimable, jcc_only, sort
--  · offer_claims + claim_offer(secret, offer_id, taula) + my_offers(secret)
--  · notices.push: en publicar un avís, un trigger crida la funció Edge send-push
-- =====================================================================

-- =====================================================================
-- OPCIONS DELS PRODUCTES (migració jaleo_menu_options)
-- menu_items.options = {"label","mixLabel","choices":[{"name":"Gin","mix":["Tònica","Sprite"]}, {"name":"Tequila"}]}
-- place_order accepta per línia {id, qty, choice, mix} i valida que la mescla existeixi.
-- =====================================================================

-- =====================================================================
-- FITXA DEL CLIENT DES DEL PANELL (migració jaleo_staff_profile_scan)
-- staff_profile(codi) i adjust_points(codi, ±punts, motiu): només personal.
-- =====================================================================

-- =====================================================================
-- GOOGLE WALLET (migració jaleo_google_wallet_v2)
-- customers.gwallet + trigger customers_gwallet: quan canvien punts/JCC/nom crida la funció Edge google-wallet (sync).
-- =====================================================================

-- =====================================================================
-- AVISOS AUTOMÀTICS PERSONALITZATS (migracions jaleo_auto_push i jaleo_auto_push_schedule)
-- auto_push_rules (textos editables al panell) · push_log (1 per persona i dia)
-- auto_push_batch() prepara la tanda a les 19 h de Reus · funció Edge auto-push l'envia
-- pg_cron 'jaleo-auto-push' cada dia a les 17:02 i 18:02 UTC (només actua quan a Reus són les 19 h)
-- =====================================================================

-- =====================================================================
-- ESTADÍSTIQUES I DRETS RGPD (migracions jaleo_staff_stats i jaleo_delete_my_data)
-- staff_stats(dies) · delete_my_card(secret) · staff_delete_customer(codi) · erase_customer(id)
-- =====================================================================

-- jaleo_packs_and_daily_offers: menu_items.only_day (null = sempre; data = només aquella nit de servei),
-- note (text curt a la carta), min_spend (regal a 0 € que exigeix X € a la resta de la comanda, màx. 1).
-- options.kind = 'pack' amb parts [{type:'one',label,choices}|{type:'count',label,n,choices}];
-- place_order valida la tria (suma exacta de n) i desa la descripció al nom de la línia.

-- jaleo_pack_max_kinds: parts[].max_kinds (Pack Jaleo / Pack Taula: refrescos de com a màxim 2 tipus); place_order -> MAX_KINDS.
