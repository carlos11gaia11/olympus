-- OLYMPUS V7 · Agenda de scrims, tiers, reputação, rankings editáveis
-- Executar uma vez APÓS schema.sql, ATUALIZACAO-SEGURA.sql,
-- REPORTS-MODERACAO.sql e migrações V3, V4, V5, V6.
-- Faça backup antes. Não rode as migrações anteriores novamente.
BEGIN;

-- Reputação: 50 ao entrar, faixa inclusiva de 0 até 100.
-- Atualiza zeros legados não associados a punições; preserva penalidades registradas.
ALTER TABLE public.profiles ALTER COLUMN reputation SET DEFAULT 50;
ALTER TABLE public.team_stats ALTER COLUMN reputation SET DEFAULT 50;
UPDATE public.profiles p SET reputation=50 WHERE p.reputation=0 AND NOT EXISTS (
  SELECT 1 FROM public.report_penalty_log l WHERE l.target_type='player' AND l.target_id=p.id
);
UPDATE public.team_stats s SET reputation=50 WHERE s.reputation=0 AND NOT EXISTS (
  SELECT 1 FROM public.report_penalty_log l WHERE l.target_type='team' AND l.target_id=s.team_id
);
UPDATE public.profiles SET reputation=greatest(0,least(100,reputation)) WHERE reputation NOT BETWEEN 0 AND 100;
UPDATE public.team_stats SET reputation=greatest(0,least(100,reputation)) WHERE reputation NOT BETWEEN 0 AND 100;
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_reputation_v7_range;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_reputation_v7_range CHECK(reputation BETWEEN 0 AND 100);
ALTER TABLE public.team_stats DROP CONSTRAINT IF EXISTS team_reputation_v7_range;
ALTER TABLE public.team_stats ADD CONSTRAINT team_reputation_v7_range CHECK(reputation BETWEEN 0 AND 100);

-- Tier S, A, B, C, D, E, F. Elo informado apenas no cadastro.
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS initial_elo text NOT NULL DEFAULT 'Não classificado';
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS player_tier text NOT NULL DEFAULT 'F';
ALTER TABLE public.teams ADD COLUMN IF NOT EXISTS team_tier text NOT NULL DEFAULT 'F';
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS player_tier_v7_check;
ALTER TABLE public.profiles ADD CONSTRAINT player_tier_v7_check CHECK(player_tier IN ('S','A','B','C','D','E','F'));
ALTER TABLE public.teams DROP CONSTRAINT IF EXISTS team_tier_v7_check;
ALTER TABLE public.teams ADD CONSTRAINT team_tier_v7_check CHECK(team_tier IN ('S','A','B','C','D','E','F'));
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS initial_elo_v7_check;
ALTER TABLE public.profiles ADD CONSTRAINT initial_elo_v7_check CHECK(initial_elo IN
 ('Não classificado','Ferro','Bronze','Prata','Ouro','Platina','Esmeralda','Diamante','Mestre','Grão-Mestre','Desafiante'));

CREATE OR REPLACE FUNCTION public.olympus_initial_tier(p_elo text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE
  WHEN p_elo IN ('Desafiante','Grão-Mestre','Mestre') THEN 'S'
  WHEN p_elo='Diamante' THEN 'A' WHEN p_elo='Esmeralda' THEN 'B'
  WHEN p_elo='Platina' THEN 'C' WHEN p_elo='Ouro' THEN 'D'
  WHEN p_elo IN ('Prata','Bronze') THEN 'E' ELSE 'F' END;
$$;

-- Reaproveita política segura de cadastro sem conceder ao cliente o tier.
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE chosen_role uuid; elo text;
BEGIN
 SELECT id INTO chosen_role FROM public.roles WHERE name=CASE
  WHEN lower(new.email)='carlosgaia1100@gmail.com' AND new.email_confirmed_at IS NOT NULL THEN 'Adm'
  ELSE 'Usuario' END LIMIT 1;
 elo:=coalesce(new.raw_user_meta_data->>'initial_elo','Não classificado');
 IF elo NOT IN ('Não classificado','Ferro','Bronze','Prata','Ouro','Platina','Esmeralda','Diamante','Mestre','Grão-Mestre','Desafiante') THEN elo:='Não classificado'; END IF;
 INSERT INTO public.profiles(id,email,full_name,nickname,birth_date,lol_role,role_id,initial_elo,player_tier,reputation)
 VALUES(new.id,new.email,coalesce(new.raw_user_meta_data->>'full_name',''),coalesce(new.raw_user_meta_data->>'nickname',''),
 nullif(new.raw_user_meta_data->>'birth_date','')::date,new.raw_user_meta_data->>'lol_role',chosen_role,
 elo,public.olympus_initial_tier(elo),50)
 ON CONFLICT(id) DO NOTHING;
 RETURN new;
END $$;

-- Mesma proteção de privilégios original, agora também inclui tier e elo.
CREATE OR REPLACE FUNCTION public.guard_profile_privileges() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF auth.uid() IS NOT NULL AND NOT public.has_permission('all') THEN
  IF new.id IS DISTINCT FROM old.id OR new.role_id IS DISTINCT FROM old.role_id
    OR new.reputation IS DISTINCT FROM old.reputation OR new.email IS DISTINCT FROM old.email
    OR new.player_tier IS DISTINCT FROM old.player_tier OR new.initial_elo IS DISTINCT FROM old.initial_elo THEN
    RAISE EXCEPTION 'Sem permissão para modificar campos administrativos';
  END IF;
 END IF;
 RETURN new;
END $$;

CREATE OR REPLACE FUNCTION public.guard_team_tier_v7() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.team_tier IS DISTINCT FROM OLD.team_tier AND NOT public.has_permission('all') THEN
  RAISE EXCEPTION 'Apenas o conselho / ADM altera o tier do time';
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_team_tier_v7 ON public.teams;
CREATE TRIGGER guard_team_tier_v7 BEFORE UPDATE ON public.teams
FOR EACH ROW EXECUTE FUNCTION public.guard_team_tier_v7();

-- Endurece a antiga política que permite ao staff editar OP.GG: usuários não
-- administrativos não podem aproveitar UPDATE para trocar cargo, jogador ou time.
CREATE OR REPLACE FUNCTION public.guard_member_staff_fields_v7() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NOT NULL AND NOT public.has_permission('all') THEN
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.team_id IS DISTINCT FROM OLD.team_id
   OR NEW.profile_id IS DISTINCT FROM OLD.profile_id OR NEW.team_role IS DISTINCT FROM OLD.team_role
   OR NEW.joined_at IS DISTINCT FROM OLD.joined_at THEN
   RAISE EXCEPTION 'Somente ADM pode alterar vínculos ou cargos da equipe';
  END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_member_staff_fields_v7 ON public.team_members;
CREATE TRIGGER guard_member_staff_fields_v7 BEFORE UPDATE ON public.team_members
FOR EACH ROW EXECUTE FUNCTION public.guard_member_staff_fields_v7();

-- Criação do time já parte de 50 de reputação.
CREATE OR REPLACE FUNCTION public.create_owned_team(p_name text,p_tag text,p_description text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login para criar um time'; END IF;
 IF length(trim(coalesce(p_name,''))) NOT BETWEEN 3 AND 65 THEN RAISE EXCEPTION 'Nome: 3 a 65 caracteres'; END IF;
 IF length(trim(coalesce(p_tag,''))) NOT BETWEEN 2 AND 8 THEN RAISE EXCEPTION 'Tag: 2 a 8 caracteres'; END IF;
 INSERT INTO public.teams(name,tag,description,created_by,division,team_tier)
 VALUES(trim(p_name),upper(trim(p_tag)),left(coalesce(p_description,''),1500),auth.uid(),'Divisão B','F') RETURNING id INTO v_id;
 INSERT INTO public.team_stats(team_id,reputation) VALUES(v_id,50) ON CONFLICT(team_id) DO NOTHING;
 INSERT INTO public.team_members(team_id,profile_id,team_role)
 VALUES(v_id,auth.uid(),'manager') ON CONFLICT(team_id,profile_id) DO NOTHING;
 RETURN v_id;
END $$;

-- Agenda livre: vaga de scrim é um registro real e visível; ocupação é atômica.
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS open_slot boolean NOT NULL DEFAULT false;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS open_slot_created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL;
ALTER TABLE public.matches ADD COLUMN IF NOT EXISTS open_slot_notes text NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS matches_open_v7_idx ON public.matches(scheduled_at,division)
 WHERE open_slot=true AND team_b IS NULL AND status='AGENDADA';

CREATE OR REPLACE FUNCTION public.scrim_team_can_manage(p_team uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT public.has_permission('all') OR EXISTS(
 SELECT 1 FROM public.teams t WHERE t.id=p_team AND t.created_by=auth.uid()) OR EXISTS(
 SELECT 1 FROM public.team_members tm WHERE tm.team_id=p_team AND tm.profile_id=auth.uid()
 AND tm.team_role IN ('manager','coach','staff'));
$$;
REVOKE ALL ON FUNCTION public.scrim_team_can_manage(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.scrim_team_can_manage(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.scrim_schedule_conflict(p_team uuid,p_at timestamptz,p_except uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.matches m WHERE m.id IS DISTINCT FROM p_except
 AND m.status IN ('AGENDADA','CONFIRMADA') AND p_team IN(m.team_a,m.team_b)
 AND m.scheduled_at > p_at - interval '2 hours' AND m.scheduled_at < p_at + interval '2 hours');
$$;
REVOKE ALL ON FUNCTION public.scrim_schedule_conflict(uuid,timestamptz,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.create_scrim_slot(p_team uuid,p_format text,p_scheduled_at timestamptz,p_notes text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE t public.teams%ROWTYPE; new_id uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.scrim_team_can_manage(p_team) THEN RAISE EXCEPTION 'Você não pode abrir agenda para este time'; END IF;
 IF p_format NOT IN ('MD1','MD3','MD5') THEN RAISE EXCEPTION 'Formato inválido'; END IF;
 IF p_scheduled_at IS NULL OR p_scheduled_at <= now()+interval '15 minutes' THEN RAISE EXCEPTION 'Agende com ao menos 15 minutos de antecedência'; END IF;
 IF p_scheduled_at > now()+interval '90 days' THEN RAISE EXCEPTION 'Agenda disponível para os próximos 90 dias'; END IF;
 SELECT * INTO t FROM public.teams WHERE id=p_team FOR UPDATE;
 IF NOT FOUND OR t.division NOT IN ('Divisão A','Divisão B') THEN RAISE EXCEPTION 'Time não tem divisão válida'; END IF;
 IF public.scrim_schedule_conflict(p_team,p_scheduled_at) THEN RAISE EXCEPTION 'Este time já tem scrim próxima deste horário'; END IF;
 INSERT INTO public.matches(team_a,team_b,division,match_format,scheduled_at,status,open_slot,open_slot_created_by,open_slot_notes)
 VALUES(t.id,NULL,t.division,p_format,p_scheduled_at,'AGENDADA',true,auth.uid(),left(trim(coalesce(p_notes,'')),280))
 RETURNING id INTO new_id;
 RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION public.claim_scrim_slot(p_match_id uuid,p_team uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.matches%ROWTYPE; t public.teams%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR NOT public.scrim_team_can_manage(p_team) THEN RAISE EXCEPTION 'Você não pode representar este time'; END IF;
 SELECT * INTO t FROM public.teams WHERE id=p_team FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Time não encontrado'; END IF;
 SELECT * INTO m FROM public.matches WHERE id=p_match_id FOR UPDATE;
 IF NOT FOUND OR NOT m.open_slot OR m.team_b IS NOT NULL OR m.status<>'AGENDADA' THEN RAISE EXCEPTION 'Vaga não está mais disponível'; END IF;
 IF m.scheduled_at<=now()+interval '15 minutes' THEN RAISE EXCEPTION 'Prazo de entrada encerrado'; END IF;
 IF m.team_a=p_team OR m.division<>t.division THEN RAISE EXCEPTION 'Escolha outro time da mesma divisão'; END IF;
 IF public.scrim_schedule_conflict(p_team,m.scheduled_at,m.id) THEN RAISE EXCEPTION 'Seu time já tem partida próxima deste horário'; END IF;
 UPDATE public.matches SET team_b=p_team,open_slot=false WHERE id=m.id;
END $$;

CREATE OR REPLACE FUNCTION public.cancel_scrim_slot(p_match_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE m public.matches%ROWTYPE;
BEGIN
 SELECT * INTO m FROM public.matches WHERE id=p_match_id FOR UPDATE;
 IF NOT FOUND OR NOT m.open_slot OR m.team_b IS NOT NULL OR m.status<>'AGENDADA' THEN RAISE EXCEPTION 'Somente vagas abertas podem ser canceladas aqui'; END IF;
 IF NOT public.scrim_team_can_manage(m.team_a) THEN RAISE EXCEPTION 'Somente a equipe responsável pode cancelar'; END IF;
 UPDATE public.matches SET status='CANCELADA',open_slot=false WHERE id=m.id;
END $$;
REVOKE ALL ON FUNCTION public.create_scrim_slot(uuid,text,timestamptz,text),public.claim_scrim_slot(uuid,uuid),
 public.cancel_scrim_slot(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_scrim_slot(uuid,text,timestamptz,text),public.claim_scrim_slot(uuid,uuid),
 public.cancel_scrim_slot(uuid) TO authenticated;

-- Redes sociais cadastradas pelo ADM, sem URLs inventadas de perfis.
CREATE TABLE IF NOT EXISTS public.platform_settings (
 id smallint PRIMARY KEY DEFAULT 1 CHECK(id=1),
 social_links jsonb NOT NULL DEFAULT '{}'::jsonb,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.platform_settings(id,social_links) VALUES(1,'{}'::jsonb) ON CONFLICT(id) DO NOTHING;
CREATE OR REPLACE FUNCTION public.guard_social_links_v7() RETURNS trigger
LANGUAGE plpgsql SET search_path='' AS $$
DECLARE k text; v text; permitted text;
BEGIN
 IF jsonb_typeof(NEW.social_links)<>'object' THEN RAISE EXCEPTION 'Links sociais inválidos'; END IF;
 FOR k,v IN SELECT key,value FROM jsonb_each_text(NEW.social_links) LOOP
  IF k NOT IN ('instagram','discord','youtube','tiktok','twitch') THEN RAISE EXCEPTION 'Rede social não suportada'; END IF;
  IF length(v)>300 THEN RAISE EXCEPTION 'Link excede 300 caracteres'; END IF;
  IF v='' THEN CONTINUE; END IF;
  permitted:=CASE k WHEN 'instagram' THEN 'instagram\.com'
  WHEN 'discord' THEN '(discord\.gg|discord\.com)'
  WHEN 'youtube' THEN '(youtube\.com|youtu\.be)'
  WHEN 'tiktok' THEN 'tiktok\.com' WHEN 'twitch' THEN 'twitch\.tv' END;
  IF NOT (v ~* ('^https://(www\.)?'||permitted||'(/|$|\?)')) THEN
   RAISE EXCEPTION 'Endereço não permitido para %',k;
  END IF;
 END LOOP;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_social_links_v7 ON public.platform_settings;
CREATE TRIGGER guard_social_links_v7 BEFORE INSERT OR UPDATE ON public.platform_settings
FOR EACH ROW EXECUTE FUNCTION public.guard_social_links_v7();
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_settings FROM PUBLIC,anon,authenticated;
GRANT SELECT,UPDATE ON public.platform_settings TO authenticated;
DROP POLICY IF EXISTS social_read_v7 ON public.platform_settings;
CREATE POLICY social_read_v7 ON public.platform_settings FOR SELECT TO authenticated USING(true);
DROP POLICY IF EXISTS social_admin_v7 ON public.platform_settings;
CREATE POLICY social_admin_v7 ON public.platform_settings FOR UPDATE TO authenticated
 USING(public.has_permission('all')) WITH CHECK(public.has_permission('all'));

-- Compensações de pontuação, independentes das partidas e separadas por divisão.
CREATE TABLE IF NOT EXISTS public.ranking_adjustments (
 category text NOT NULL CHECK(category IN ('SCRIM','INHOUSE')),
 entity_id uuid NOT NULL,
 division text NOT NULL,
 points numeric(12,1) NOT NULL DEFAULT 0,
 updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 reason text NOT NULL DEFAULT '',
 updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(category,entity_id,division),
 CONSTRAINT adjustment_division_v7 CHECK((category='INHOUSE' AND division='GERAL') OR (category='SCRIM' AND division IN ('Divisão A','Divisão B')))
);
ALTER TABLE public.ranking_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ranking_adjustments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ranking_adjustments TO authenticated;
DROP POLICY IF EXISTS rank_adjust_read_v7 ON public.ranking_adjustments;
CREATE POLICY rank_adjust_read_v7 ON public.ranking_adjustments FOR SELECT TO authenticated USING(true);

-- Views continuam com as mesmas colunas para não quebrar outros módulos.
CREATE OR REPLACE VIEW public.scrim_ranking WITH (security_invoker=true) AS
WITH results AS (
 SELECT m.division,m.match_format,m.score_a AS pf,m.score_b AS pa,m.team_a AS team_id,m.created_at
 FROM public.matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b AND m.team_a IS NOT NULL
 UNION ALL
 SELECT m.division,m.match_format,m.score_b AS pf,m.score_a AS pa,m.team_b AS team_id,m.created_at
 FROM public.matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b AND m.team_b IS NOT NULL
), counted AS (
 SELECT t.id AS team_id,t.division,
  CASE WHEN l.division=t.division THEN l.games ELSE 0 END AS base_games,
  CASE WHEN l.division=t.division THEN l.wins ELSE 0 END AS base_wins,
  CASE WHEN l.division=t.division THEN l.losses ELSE 0 END AS base_losses,
  CASE WHEN l.division=t.division THEN l.md3 ELSE 0 END AS base_md3,
  CASE WHEN l.division=t.division THEN l.md5 ELSE 0 END AS base_md5,
  CASE WHEN l.division=t.division THEN l.points ELSE 0 END AS base_points,
  count(r.team_id)::integer AS new_games,
  count(r.team_id) FILTER(WHERE r.pf>r.pa)::integer AS new_wins,
  count(r.team_id) FILTER(WHERE r.pf<r.pa)::integer AS new_losses,
  count(r.team_id) FILTER(WHERE r.match_format='MD3')::integer AS new_md3,
  count(r.team_id) FILTER(WHERE r.match_format='MD5')::integer AS new_md5,
  coalesce(sum(public.olympus_series_points(r.pf>r.pa,r.match_format,r.pf,r.pa)),0) AS new_points
 FROM public.teams t
 LEFT JOIN public.scrim_legacy_stats l ON l.team_id=t.id
 LEFT JOIN results r ON r.team_id=t.id AND r.division=t.division AND (
   l.team_id IS NULL OR (l.games=0 AND l.wins=0 AND l.losses=0 AND l.points=0 AND l.md3=0 AND l.md5=0)
   OR r.created_at>l.imported_at)
 GROUP BY t.id,t.division,l.division,l.games,l.wins,l.losses,l.md3,l.md5,l.points
)
SELECT c.team_id,c.division,
 (base_games+new_games)::integer AS games,
 (base_wins+new_wins)::integer AS wins,
 (base_losses+new_losses)::integer AS losses,
 (base_md3+new_md3)::integer AS md3,
 (base_md5+new_md5)::integer AS md5,
 (base_points+new_points+coalesce(adj.points,0))::numeric(12,1) AS points,
 CASE WHEN base_games+new_games=0 THEN 0
 ELSE round(100.0*(base_wins+new_wins)/(base_games+new_games),1) END AS winrate
FROM counted c
LEFT JOIN public.ranking_adjustments adj ON adj.category='SCRIM' AND adj.entity_id=c.team_id AND adj.division=c.division;
GRANT SELECT ON public.scrim_ranking TO authenticated;

CREATE OR REPLACE VIEW public.inhouse_ranking WITH (security_invoker=true) AS
WITH results AS (
 SELECT m.player_a AS player_id,m.match_format,m.score_a AS pf,m.score_b AS pa
 FROM public.inhouse_matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b
 UNION ALL
 SELECT m.player_b,m.match_format,m.score_b,m.score_a
 FROM public.inhouse_matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b
 UNION ALL
 SELECT q.player_id,'MD3'::text AS match_format,
 CASE WHEN coalesce(q.draft_side,q.side)=l.winner_side THEN 2 ELSE least(l.score_a,l.score_b) END AS pf,
 CASE WHEN coalesce(q.draft_side,q.side)=l.winner_side THEN least(l.score_a,l.score_b) ELSE 2 END AS pa
 FROM public.inhouse_lobbies l
 JOIN public.inhouse_queue_entries q ON q.lobby_id=l.id AND q.status='CONFIRMED'
 WHERE l.status='FINALIZADA' AND l.winner_side IS NOT NULL
)
SELECT p.id AS player_id,
 count(r.player_id)::integer AS games,
 count(r.player_id) FILTER(WHERE r.pf>r.pa)::integer AS wins,
 count(r.player_id) FILTER(WHERE r.pf<r.pa)::integer AS losses,
 count(r.player_id) FILTER(WHERE r.match_format='MD3')::integer AS md3,
 count(r.player_id) FILTER(WHERE r.match_format='MD5')::integer AS md5,
 (coalesce(sum(public.olympus_series_points(r.pf>r.pa,r.match_format,r.pf,r.pa)),0)+coalesce(max(adj.points),0))::numeric(12,1) AS points,
 CASE WHEN count(r.player_id)=0 THEN 0
 ELSE round(100.0*count(r.player_id) FILTER(WHERE r.pf>r.pa)/count(r.player_id),1) END AS winrate
FROM public.profiles p LEFT JOIN results r ON r.player_id=p.id
LEFT JOIN public.ranking_adjustments adj ON adj.category='INHOUSE' AND adj.entity_id=p.id AND adj.division='GERAL'
GROUP BY p.id;
GRANT SELECT ON public.inhouse_ranking TO authenticated;

-- Recebe a pontuação TOTAL desejada, e armazena apenas a diferença da base;
-- novos resultados homologados continuam somando depois de uma edição manual.
CREATE OR REPLACE FUNCTION public.admin_set_ranking_points(
 p_category text,p_id uuid,p_division text,p_target_points numeric,p_reason text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE old_total numeric; previous_adjustment numeric;
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_permission('all') THEN RAISE EXCEPTION 'Acesso restrito ao ADM'; END IF;
 IF p_target_points IS NULL OR p_target_points NOT BETWEEN -99999 AND 99999
 OR p_target_points<>round(p_target_points,1) THEN RAISE EXCEPTION 'Informe um total válido (até uma casa decimal)'; END IF;
 IF length(trim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'Explique o motivo do ajuste'; END IF;
 IF p_category='SCRIM' THEN
  PERFORM 1 FROM public.teams WHERE id=p_id AND division=p_division FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Time/divisão não encontrado'; END IF;
  SELECT points INTO old_total FROM public.scrim_ranking WHERE team_id=p_id AND division=p_division;
 ELSIF p_category='INHOUSE' AND p_division='GERAL' THEN
  PERFORM 1 FROM public.profiles WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jogador não encontrado'; END IF;
  SELECT points INTO old_total FROM public.inhouse_ranking WHERE player_id=p_id;
 ELSE RAISE EXCEPTION 'Tipo de ranking inválido'; END IF;
 SELECT coalesce(points,0) INTO previous_adjustment FROM public.ranking_adjustments
 WHERE category=p_category AND entity_id=p_id AND division=p_division;
 INSERT INTO public.ranking_adjustments(category,entity_id,division,points,updated_by,reason,updated_at)
 VALUES(p_category,p_id,p_division,coalesce(previous_adjustment,0)+p_target_points-coalesce(old_total,0),
 auth.uid(),trim(p_reason),now())
 ON CONFLICT(category,entity_id,division) DO UPDATE SET points=excluded.points,
 updated_by=excluded.updated_by,reason=excluded.reason,updated_at=now();
END $$;
REVOKE ALL ON FUNCTION public.admin_set_ranking_points(text,uuid,text,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_set_ranking_points(text,uuid,text,numeric,text) TO authenticated;

COMMIT;
NOTIFY pgrst,'reload schema';
