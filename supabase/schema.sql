-- OLYMPUS - schema Supabase/Postgres
-- Execute este arquivo no SQL Editor do Supabase uma vez.

create extension if not exists pgcrypto;

create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  permissions jsonb not null default '{}'::jsonb,
  is_system boolean not null default false,
  created_at timestamptz not null default now()
);

insert into public.roles(name, permissions, is_system) values
('Usuario', '{"profile_edit":true,"news_read":true,"news_like":true,"news_comment":true,"teams_read":true,"ranking_read":true,"matches_read":true}'::jsonb, true),
('Jornalista', '{"profile_edit":true,"news_read":true,"news_create":true,"news_edit_own":true,"news_like":true,"news_comment":true,"teams_read":true,"ranking_read":true,"matches_read":true}'::jsonb, true),
('Adm', '{"all":true}'::jsonb, true)
on conflict(name) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text not null default '',
  nickname text not null default '',
  birth_date date,
  lol_role text,
  bio text not null default '',
  avatar_url text,
  role_id uuid references public.roles(id),
  reputation integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  tag text not null unique,
  division text not null default 'SEM DIVISÃO',
  description text not null default '',
  whatsapp_url text,
  logo_url text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.team_members (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  team_role text not null default 'player' check(team_role in ('player','staff','coach','manager')),
  opgg_url text,
  joined_at timestamptz not null default now(),
  unique(team_id, profile_id)
);

create table if not exists public.team_stats (
  team_id uuid primary key references public.teams(id) on delete cascade,
  games integer not null default 0,
  wins integer not null default 0,
  losses integer not null default 0,
  points integer not null default 0,
  wins_md3 integer not null default 0,
  wins_md5 integer not null default 0,
  reputation integer not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.news (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  summary text not null default '',
  content text not null,
  author_id uuid references public.profiles(id) on delete set null,
  published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.news_likes (
  news_id uuid not null references public.news(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(news_id,user_id)
);

create table if not exists public.news_comments (
  id uuid primary key default gen_random_uuid(),
  news_id uuid not null references public.news(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check(char_length(content) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  division text not null default 'SEM DIVISÃO',
  team_a uuid references public.teams(id) on delete set null,
  team_b uuid references public.teams(id) on delete set null,
  match_format text not null default 'MD3' check(match_format in ('MD1','MD3','MD5')),
  scheduled_at timestamptz,
  status text not null default 'AGENDADA',
  score_a integer not null default 0,
  score_b integer not null default 0,
  winner_id uuid references public.teams(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  subject text not null,
  description text not null,
  status text not null default 'ABERTO',
  created_at timestamptz not null default now()
);

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists teams_touch on public.teams;
create trigger teams_touch before update on public.teams for each row execute function public.touch_updated_at();
drop trigger if exists news_touch on public.news;
create trigger news_touch before update on public.news for each row execute function public.touch_updated_at();

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
declare chosen_role uuid;
begin
  if not exists(select 1 from public.profiles) then
    select id into chosen_role from public.roles where name='Adm' limit 1;
  else
    select id into chosen_role from public.roles where name='Usuario' limit 1;
  end if;
  insert into public.profiles(id,email,full_name,nickname,birth_date,lol_role,role_id)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',''),coalesce(new.raw_user_meta_data->>'nickname',''),nullif(new.raw_user_meta_data->>'birth_date','')::date,new.raw_user_meta_data->>'lol_role',chosen_role)
  on conflict(id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Cria perfis para usuários que já existiam antes da instalação do schema.
insert into public.profiles(id,email,full_name,nickname,role_id)
select u.id,u.email,coalesce(u.raw_user_meta_data->>'full_name',''),coalesce(u.raw_user_meta_data->>'nickname',''),
       (select id from public.roles where name='Usuario' limit 1)
from auth.users u
left join public.profiles p on p.id=u.id
where p.id is null;

-- Se ainda não houver administrador, transforma o usuário mais antigo em Adm.
update public.profiles p
set role_id=(select id from public.roles where name='Adm' limit 1)
where p.id=(select id from public.profiles order by created_at asc limit 1)
and not exists(
  select 1 from public.profiles x join public.roles r on r.id=x.role_id where r.name='Adm'
);

create or replace function public.current_permissions() returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(r.permissions,'{}'::jsonb)
  from public.profiles p left join public.roles r on r.id=p.role_id
  where p.id=auth.uid()
$$;

create or replace function public.has_permission(k text) returns boolean
language sql stable security definer set search_path=public as $$
  select coalesce((public.current_permissions()->>'all')::boolean,false)
      or coalesce((public.current_permissions()->>k)::boolean,false)
$$;


create or replace function public.delete_user_account(target uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.has_permission('all') then
    raise exception 'Acesso negado';
  end if;
  if target=auth.uid() then
    raise exception 'O administrador não pode excluir a própria conta por este painel';
  end if;
  delete from auth.users where id=target;
end $$;
grant execute on function public.delete_user_account(uuid) to authenticated;

alter table public.roles enable row level security;
alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.team_stats enable row level security;
alter table public.news enable row level security;
alter table public.news_likes enable row level security;
alter table public.news_comments enable row level security;
alter table public.matches enable row level security;
alter table public.reports enable row level security;

-- leitura autenticada
create policy roles_read on public.roles for select to authenticated using(true);
create policy profiles_read on public.profiles for select to authenticated using(true);
create policy teams_read on public.teams for select to authenticated using(true);
create policy members_read on public.team_members for select to authenticated using(true);
create policy stats_read on public.team_stats for select to authenticated using(true);
create policy news_read on public.news for select to authenticated using(published=true or public.has_permission('all'));
create policy likes_read on public.news_likes for select to authenticated using(true);
create policy comments_read on public.news_comments for select to authenticated using(true);
create policy matches_read on public.matches for select to authenticated using(true);
create policy reports_read on public.reports for select to authenticated using(reporter_id=auth.uid() or public.has_permission('all'));

-- perfil próprio + admin
create policy profiles_update on public.profiles for update to authenticated
using(id=auth.uid() or public.has_permission('all'))
with check(id=auth.uid() or public.has_permission('all'));
create policy profiles_admin_delete on public.profiles for delete to authenticated using(public.has_permission('all'));

-- CRUD administrativo
create policy roles_admin_write on public.roles for all to authenticated using(public.has_permission('all')) with check(public.has_permission('all'));
create policy teams_admin_write on public.teams for all to authenticated using(public.has_permission('all')) with check(public.has_permission('all'));
create policy members_admin_write on public.team_members for all to authenticated using(public.has_permission('all')) with check(public.has_permission('all'));
create policy stats_admin_write on public.team_stats for all to authenticated using(public.has_permission('all')) with check(public.has_permission('all'));
create policy matches_admin_write on public.matches for all to authenticated using(public.has_permission('all')) with check(public.has_permission('all'));
create policy reports_admin_update on public.reports for update to authenticated using(public.has_permission('all')) with check(public.has_permission('all'));
create policy reports_insert on public.reports for insert to authenticated with check(reporter_id=auth.uid());

-- staff/coach/manager também pode atualizar o OP.GG dos membros do próprio time
create policy members_staff_update on public.team_members for update to authenticated
using(exists(select 1 from public.team_members me where me.team_id=team_members.team_id and me.profile_id=auth.uid() and me.team_role in ('staff','coach','manager')))
with check(exists(select 1 from public.team_members me where me.team_id=team_members.team_id and me.profile_id=auth.uid() and me.team_role in ('staff','coach','manager')));

-- notícias
create policy news_create on public.news for insert to authenticated with check(author_id=auth.uid() and public.has_permission('news_create'));
create policy news_update on public.news for update to authenticated
using(public.has_permission('all') or (author_id=auth.uid() and public.has_permission('news_edit_own')))
with check(public.has_permission('all') or (author_id=auth.uid() and public.has_permission('news_edit_own')));
create policy news_delete on public.news for delete to authenticated using(public.has_permission('all'));
create policy likes_insert on public.news_likes for insert to authenticated with check(user_id=auth.uid() and public.has_permission('news_like'));
create policy likes_delete on public.news_likes for delete to authenticated using(user_id=auth.uid() or public.has_permission('all'));
create policy comments_insert on public.news_comments for insert to authenticated with check(user_id=auth.uid() and public.has_permission('news_comment'));
create policy comments_delete on public.news_comments for delete to authenticated using(user_id=auth.uid() or public.has_permission('all'));

-- Bucket de avatares
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('avatars','avatars',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true;

create policy avatar_public_read on storage.objects for select using(bucket_id='avatars');
create policy avatar_upload_self on storage.objects for insert to authenticated
with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);
create policy avatar_update_self on storage.objects for update to authenticated
using(bucket_id='avatars' and ((storage.foldername(name))[1]=auth.uid()::text or public.has_permission('all')))
with check(bucket_id='avatars' and ((storage.foldername(name))[1]=auth.uid()::text or public.has_permission('all')));
create policy avatar_delete_self on storage.objects for delete to authenticated
using(bucket_id='avatars' and ((storage.foldername(name))[1]=auth.uid()::text or public.has_permission('all')));
