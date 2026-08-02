-- PopCook — schéma MVP Supabase
-- À exécuter une fois dans Supabase (Project → SQL Editor → New query → Run).

create extension if not exists "pgcrypto";

-- ============================================================
-- PROFILES — une ligne par utilisateur authentifié
-- ============================================================
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'client' check (role in ('client','cook','admin')),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

create policy "profiles are self-readable" on profiles
  for select using (auth.uid() = id);
create policy "profiles are self-insertable" on profiles
  for insert with check (auth.uid() = id);
create policy "profiles are self-updatable" on profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Crée automatiquement une ligne profiles à chaque inscription
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email);
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============================================================
-- COOKS — profil public d'un cuisinier, une ligne par profil
-- ============================================================
create table if not exists cooks (
  id uuid primary key references profiles(id) on delete cascade,
  name text not null,
  initials text not null,
  color text not null default 'linear-gradient(150deg,#F4C892,#F0872A)',
  photo text,
  cuisine text not null,
  specialty text,
  bio text,
  quartier text,
  distance text default '—',
  verified boolean not null default false,
  rating numeric(2,1) not null default 5.0,
  reviews_count int not null default 0,
  created_at timestamptz not null default now()
);

alter table cooks enable row level security;

create policy "cooks are publicly readable" on cooks
  for select using (true);
create policy "a user manages only their own cook profile" on cooks
  for all using (auth.uid() = id) with check (auth.uid() = id);

-- ============================================================
-- DISHES — plats publiés par un cuisinier
-- ============================================================
create table if not exists dishes (
  id uuid primary key default gen_random_uuid(),
  cook_id uuid not null references cooks(id) on delete cascade,
  name text not null,
  kind text not null default 'tajine',
  description text,
  price numeric(6,2) not null,
  allergens text[] not null default '{}',
  qty int not null default 0,
  slot text,
  tag text,
  photo text,
  created_at timestamptz not null default now()
);

create index if not exists dishes_cook_id_idx on dishes(cook_id);

alter table dishes enable row level security;

create policy "dishes are publicly readable" on dishes
  for select using (true);
create policy "a cook manages only their own dishes" on dishes
  for all using (auth.uid() = cook_id) with check (auth.uid() = cook_id);

-- ============================================================
-- ORDERS — commandes passées par les clients
-- ============================================================
create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references profiles(id) on delete cascade,
  cook_id uuid not null references cooks(id) on delete cascade,
  dish_id uuid not null references dishes(id) on delete cascade,
  dish_name text not null,
  cook_name text not null,
  qty int not null default 1,
  total numeric(7,2) not null,
  slot text,
  status text not null default 'attente' check (status in ('attente','confirmee','retiree','annulee')),
  reviewed boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists orders_client_id_idx on orders(client_id);
create index if not exists orders_cook_id_idx on orders(cook_id);

alter table orders enable row level security;

create policy "orders are readable by the client or the cook involved" on orders
  for select using (auth.uid() = client_id or auth.uid() = cook_id);
create policy "clients create their own orders" on orders
  for insert with check (auth.uid() = client_id);
create policy "clients update their own orders (ex: laisser un avis)" on orders
  for update using (auth.uid() = client_id) with check (auth.uid() = client_id);
create policy "cooks update the status of their own orders" on orders
  for update using (auth.uid() = cook_id) with check (auth.uid() = cook_id);

-- ============================================================
-- place_order — insère la commande et décrémente le stock du plat
-- de façon atomique (évite la survente si deux clients commandent
-- le même plat en même temps).
-- ============================================================
create or replace function public.place_order(p_dish_id uuid, p_qty int)
returns orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dish dishes;
  v_cook cooks;
  v_order orders;
begin
  if auth.uid() is null then
    raise exception 'Vous devez être connecté pour commander';
  end if;

  select * into v_dish from dishes where id = p_dish_id for update;
  if v_dish is null then
    raise exception 'Plat introuvable';
  end if;
  if v_dish.qty < p_qty then
    raise exception 'Quantité insuffisante disponible';
  end if;

  select * into v_cook from cooks where id = v_dish.cook_id;

  update dishes set qty = qty - p_qty where id = p_dish_id;

  insert into orders (client_id, cook_id, dish_id, dish_name, cook_name, qty, total, slot)
  values (auth.uid(), v_dish.cook_id, v_dish.id, v_dish.name, v_cook.name, p_qty, v_dish.price * p_qty, v_dish.slot)
  returning * into v_order;

  return v_order;
end;
$$;

grant execute on function public.place_order(uuid, int) to authenticated;

-- ============================================================
-- Notes de portée MVP :
-- - Pas de seed de démo : la table cooks démarre vide, l'appli
--   continue d'afficher les cuisiniers de démo tant qu'aucun vrai
--   cuisinier ne s'est inscrit (voir index.html, loadCooksAndDishes).
-- - La validation admin des cuisiniers, la modération et les
--   paiements en ligne restent hors périmètre de ce premier MVP.
-- ============================================================
