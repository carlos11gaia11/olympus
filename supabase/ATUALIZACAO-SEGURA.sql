-- OLYMPUS - atualização incremental. Executar APÓS schema.sql, no SQL Editor.
-- ATENÇÃO: revise backups antes de qualquer migração em produção.
-- Identidade master: baseada em auth.users, nunca em uma string controlada pelo cliente.
create or replace function public.is_master() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from auth.users u where u.id=auth.uid()
    and lower(u.email)='carlosgaia1100@gmail.com' and u.email_confirmed_at is not null)
$$;
revoke all on function public.is_master() from public, anon;
grant execute on function public.is_master() to authenticated;

-- Não deixe o primeiro usuário aleatório virar administrador.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
declare chosen_role uuid;
begin
  select id into chosen_role from public.roles where name=case
    when lower(new.email)='carlosgaia1100@gmail.com' and new.email_confirmed_at is not null then 'Adm'
    else 'Usuario' end limit 1;
  insert into public.profiles(id,email,full_name,nickname,birth_date,lol_role,role_id)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',''),coalesce(new.raw_user_meta_data->>'nickname',''),
    nullif(new.raw_user_meta_data->>'birth_date','')::date,new.raw_user_meta_data->>'lol_role',chosen_role)
  on conflict(id) do nothing;
  return new;
end $$;

-- O master tem acesso total mesmo se seu cargo ainda não estiver vinculado.
create or replace function public.has_permission(k text) returns boolean
language sql stable security definer set search_path=public as $$
 select public.is_master() or coalesce((public.current_permissions()->>'all')::boolean,false)
     or coalesce((public.current_permissions()->>k)::boolean,false)
$$;

-- Perfil próprio: bloquear alteração de role_id, reputação, email ou id por usuário comum.
create or replace function public.guard_profile_privileges() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is not null and not public.has_permission('all') then
    if new.id is distinct from old.id or new.role_id is distinct from old.role_id
       or new.reputation is distinct from old.reputation or new.email is distinct from old.email then
      raise exception 'Sem permissão para modificar campos administrativos';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_profile_privileges on public.profiles;
create trigger guard_profile_privileges before update on public.profiles
for each row execute function public.guard_profile_privileges();

-- Master recebe cargo Adm se a conta já existir. Outros administradores já
-- autorizados são preservados para evitar perda inesperada de acesso.
update public.profiles p set role_id=(select id from public.roles where name='Adm')
from auth.users u where u.id=p.id and lower(u.email)='carlosgaia1100@gmail.com'
and u.email_confirmed_at is not null and p.role_id is distinct from (select id from public.roles where name='Adm');

-- A conta master não pode ser excluída nem rebaixada por outros administradores.
create or replace function public.guard_master_profile() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from auth.users u where u.id=old.id and lower(u.email)='carlosgaia1100@gmail.com') then
   if tg_op='DELETE' then raise exception 'Conta master protegida'; end if;
   if new.role_id is distinct from old.role_id then raise exception 'Cargo master protegido'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
drop trigger if exists guard_master_profile on public.profiles;
create trigger guard_master_profile before update or delete on public.profiles
for each row execute function public.guard_master_profile();

create or replace function public.delete_user_account(target uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.has_permission('all') then raise exception 'Acesso negado'; end if;
 if target=auth.uid() or exists(select 1 from auth.users where id=target and lower(email)='carlosgaia1100@gmail.com') then
    raise exception 'Não é permitido excluir essa conta';
 end if;
 delete from auth.users where id=target;
end $$;

-- Confirmação temporal feita no servidor, apenas admin ou integrante da partida.
create or replace function public.confirm_match(target uuid) returns void
language plpgsql security definer set search_path=public as $$
declare m public.matches%rowtype;
begin
 select * into m from public.matches where id=target for update;
 if not found then raise exception 'Agendamento não encontrado'; end if;
 if m.scheduled_at is null or now()<m.scheduled_at then raise exception 'Aguarde o horário agendado'; end if;
 if m.status <> 'AGENDADA' then raise exception 'Esta partida já foi confirmada ou finalizada'; end if;
 if not (public.has_permission('all') or exists (
   select 1 from public.team_members tm where tm.profile_id=auth.uid()
   and tm.team_id in (m.team_a,m.team_b))) then raise exception 'Você não pertence a esta partida'; end if;
 update public.matches set status='CONFIRMADA' where id=target;
end $$;
revoke all on function public.confirm_match(uuid) from public,anon;
grant execute on function public.confirm_match(uuid) to authenticated;

-- Importante: as policies de schema.sql antigas continuam válidas; não executar
-- o schema inicial novamente após esta atualização sem revisar políticas.
