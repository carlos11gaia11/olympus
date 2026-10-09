-- OLYMPUS v3 - MIGRAÇÃO INCREMENTAL (não executar schema.sql novamente)
-- Pré-requisitos: schema.sql, ATUALIZACAO-SEGURA.sql e REPORTS-MODERACAO.sql.
-- Execute no SQL Editor do Supabase, depois de fazer backup do banco.
BEGIN;

-- Equipes sempre possuem uma divisão válida; os dados legados ficam inicialmente na Divisão B.
UPDATE public.teams SET division='Divisão B' WHERE division NOT IN ('Divisão A','Divisão B') OR division IS NULL;
ALTER TABLE public.teams ALTER COLUMN division SET DEFAULT 'Divisão B';
ALTER TABLE public.teams DROP CONSTRAINT IF EXISTS teams_division_v3_check;
ALTER TABLE public.teams ADD CONSTRAINT teams_division_v3_check CHECK (division IN ('Divisão A','Divisão B'));
CREATE INDEX IF NOT EXISTS teams_created_by_v3_idx ON public.teams(created_by);
-- A divisão da scrim é registrada no convite; placares legados de divisões antigas
-- não são inventados nem recalculados retroativamente.
ALTER TABLE public.matches ALTER COLUMN division SET DEFAULT 'Divisão B';
ALTER TABLE public.matches DROP CONSTRAINT IF EXISTS matches_division_v3_check;
ALTER TABLE public.matches ADD CONSTRAINT matches_division_v3_check CHECK (division IN ('Divisão A','Divisão B','SEM DIVISÃO'));

-- A pessoa autenticada é a dona do time. O backend cria o time, sua reputação
-- e o vínculo como gerente em uma única transação.
CREATE OR REPLACE FUNCTION public.create_owned_team(p_name text,p_tag text,p_description text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login para criar um time'; END IF;
  IF length(trim(coalesce(p_name,''))) NOT BETWEEN 3 AND 65 THEN RAISE EXCEPTION 'Nome: 3 a 65 caracteres'; END IF;
  IF length(trim(coalesce(p_tag,''))) NOT BETWEEN 2 AND 8 THEN RAISE EXCEPTION 'Tag: 2 a 8 caracteres'; END IF;
  INSERT INTO public.teams(name,tag,description,created_by,division)
    VALUES(trim(p_name),upper(trim(p_tag)),left(coalesce(p_description,''),1500),auth.uid(),'Divisão B') RETURNING id INTO v_id;
  INSERT INTO public.team_stats(team_id,reputation) VALUES(v_id,0) ON CONFLICT(team_id) DO NOTHING;
  INSERT INTO public.team_members(team_id,profile_id,team_role) VALUES(v_id,auth.uid(),'manager') ON CONFLICT(team_id,profile_id) DO NOTHING;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.create_owned_team(text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_owned_team(text,text,text) TO authenticated;

-- Só o ADM altera divisão. Mantém o criador atrelado ao time no banco.
CREATE OR REPLACE FUNCTION public.guard_team_owner_division_v3()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN RAISE EXCEPTION 'O dono do time não pode ser alterado'; END IF;
    IF NEW.division IS DISTINCT FROM OLD.division AND NOT public.has_permission('all') THEN RAISE EXCEPTION 'Apenas o ADM altera a divisão'; END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_team_owner_division_v3 ON public.teams;
CREATE TRIGGER guard_team_owner_division_v3 BEFORE UPDATE ON public.teams
  FOR EACH ROW EXECUTE FUNCTION public.guard_team_owner_division_v3();

-- Convites de scrim de um dono de time para outro.
CREATE TABLE IF NOT EXISTS public.scrim_invites (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 from_team uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
 to_team uuid NOT NULL REFERENCES public.teams(id) ON DELETE CASCADE,
 created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 match_format text NOT NULL CHECK (match_format IN ('MD3','MD5')),
 scheduled_at timestamptz NOT NULL,
 division text NOT NULL CHECK (division IN ('Divisão A','Divisão B')),
 status text NOT NULL DEFAULT 'PENDENTE' CHECK(status IN ('PENDENTE','ACEITO','RECUSADO')),
 match_id uuid REFERENCES public.matches(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 answered_at timestamptz,
 CONSTRAINT scrim_invites_distinct_v3 CHECK(from_team<>to_team)
);
CREATE INDEX IF NOT EXISTS scrim_invites_teams_v3_idx ON public.scrim_invites(from_team,to_team,status);
ALTER TABLE public.scrim_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.scrim_invites FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.scrim_invites TO authenticated;
DROP POLICY IF EXISTS scrim_invites_visible_v3 ON public.scrim_invites;
CREATE POLICY scrim_invites_visible_v3 ON public.scrim_invites FOR SELECT TO authenticated
USING (public.has_permission('all') OR EXISTS
 (SELECT 1 FROM public.teams t WHERE t.id IN (from_team,to_team) AND t.created_by=auth.uid()));

CREATE OR REPLACE FUNCTION public.send_scrim_invite(p_from_team uuid,p_to_team uuid,p_format text,p_scheduled_at timestamptz)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE a public.teams%ROWTYPE; b public.teams%ROWTYPE; v_id uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login obrigatório'; END IF;
 SELECT * INTO a FROM public.teams WHERE id=p_from_team;
 SELECT * INTO b FROM public.teams WHERE id=p_to_team;
 IF a.id IS NULL OR b.id IS NULL OR a.id=b.id THEN RAISE EXCEPTION 'Escolha duas equipes distintas'; END IF;
 IF a.created_by IS DISTINCT FROM auth.uid() AND NOT public.has_permission('all') THEN RAISE EXCEPTION 'Somente o dono pode convidar'; END IF;
 IF a.division<>b.division THEN RAISE EXCEPTION 'Convites exigem times da mesma divisão'; END IF;
 IF p_format NOT IN ('MD3','MD5') THEN RAISE EXCEPTION 'Formato inválido'; END IF;
 IF p_scheduled_at IS NULL OR p_scheduled_at <= now() THEN RAISE EXCEPTION 'Selecione uma data futura'; END IF;
 IF EXISTS (SELECT 1 FROM public.scrim_invites WHERE from_team=a.id AND to_team=b.id AND status='PENDENTE') THEN
  RAISE EXCEPTION 'Já existe um convite pendente entre esses times'; END IF;
 INSERT INTO public.scrim_invites(from_team,to_team,created_by,match_format,scheduled_at,division)
 VALUES(a.id,b.id,auth.uid(),p_format,p_scheduled_at,a.division) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.send_scrim_invite(uuid,uuid,text,timestamptz) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.send_scrim_invite(uuid,uuid,text,timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.answer_scrim_invite(p_invite_id uuid,p_accept boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE i public.scrim_invites%ROWTYPE; a public.teams%ROWTYPE; b public.teams%ROWTYPE; mid uuid;
BEGIN
 SELECT * INTO i FROM public.scrim_invites WHERE id=p_invite_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Convite não encontrado'; END IF;
 IF i.status<>'PENDENTE' THEN RAISE EXCEPTION 'Convite já respondido'; END IF;
 SELECT * INTO a FROM public.teams WHERE id=i.from_team;
 SELECT * INTO b FROM public.teams WHERE id=i.to_team;
 IF b.created_by IS DISTINCT FROM auth.uid() AND NOT public.has_permission('all') THEN RAISE EXCEPTION 'Somente o dono do time convidado pode responder'; END IF;
 IF p_accept THEN
  IF a.division<>b.division OR i.division<>a.division THEN RAISE EXCEPTION 'Divisões alteradas; solicite um novo convite'; END IF;
  IF i.scheduled_at<=now() THEN RAISE EXCEPTION 'Convite expirou; solicite nova data'; END IF;
  INSERT INTO public.matches(team_a,team_b,division,match_format,scheduled_at,status)
   VALUES(i.from_team,i.to_team,i.division,i.match_format,i.scheduled_at,'AGENDADA') RETURNING id INTO mid;
  UPDATE public.scrim_invites SET status='ACEITO',answered_at=now(),match_id=mid WHERE id=i.id;
 ELSE
  UPDATE public.scrim_invites SET status='RECUSADO',answered_at=now() WHERE id=i.id;
 END IF;
 RETURN mid;
END $$;
REVOKE ALL ON FUNCTION public.answer_scrim_invite(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.answer_scrim_invite(uuid,boolean) TO authenticated;

-- Regras: vitória +2, derrota -1, participação +0.5,
-- MD3 +1, MD5 +2; resultados específicos de derrota MD3:
-- 1x2 = 1.5 pontos totais e 0x2 = -1 ponto total (prevalecem sobre os bônus).
-- Calculadas por partida FINALIZADA (uma série = um jogo computado).
CREATE OR REPLACE FUNCTION public.olympus_series_points(p_won boolean,p_format text,p_for integer,p_against integer)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE WHEN p_format='MD3' AND NOT p_won AND p_for=1 AND p_against=2 THEN 1.5
             WHEN p_format='MD3' AND NOT p_won AND p_for=0 AND p_against=2 THEN -1
             ELSE (CASE WHEN p_won THEN 2 ELSE -1 END)::numeric + 0.5
                  + (CASE p_format WHEN 'MD3' THEN 1 WHEN 'MD5' THEN 2 ELSE 0 END) END;
$$;

-- Snapshot do ranking de times existente, para preservar os pontos legados.
-- Se team_stats já possui resultados manuais, eles serão a pontuação inicial.
-- Partidas antigas não serão contadas novamente quando houver snapshot não zerado.
CREATE TABLE IF NOT EXISTS public.scrim_legacy_stats (
 team_id uuid PRIMARY KEY REFERENCES public.teams(id) ON DELETE CASCADE,
 division text NOT NULL,
 games integer NOT NULL DEFAULT 0,
 wins integer NOT NULL DEFAULT 0,
 losses integer NOT NULL DEFAULT 0,
 md3 integer NOT NULL DEFAULT 0,
 md5 integer NOT NULL DEFAULT 0,
 points numeric(12,1) NOT NULL DEFAULT 0,
 imported_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.scrim_legacy_stats(team_id,division,games,wins,losses,md3,md5,points)
SELECT t.id,t.division,coalesce(s.games,0),coalesce(s.wins,0),coalesce(s.losses,0),
 coalesce(s.wins_md3,0),coalesce(s.wins_md5,0),coalesce(s.points,0)::numeric(12,1)
FROM public.teams t LEFT JOIN public.team_stats s ON s.team_id=t.id
ON CONFLICT(team_id) DO NOTHING;
ALTER TABLE public.scrim_legacy_stats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.scrim_legacy_stats FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.scrim_legacy_stats TO authenticated;
DROP POLICY IF EXISTS scrim_legacy_read_v3 ON public.scrim_legacy_stats;
CREATE POLICY scrim_legacy_read_v3 ON public.scrim_legacy_stats FOR SELECT TO authenticated USING(true);

-- Rankings calculados: cada time acumula pontos APENAS na divisão da scrim.
-- A mudança de divisão não transfere a pontuação antiga. Ao trocar a divisão,
-- a pontuação legada continua associada à divisão original.
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
SELECT team_id,division,
 (base_games+new_games)::integer AS games,
 (base_wins+new_wins)::integer AS wins,
 (base_losses+new_losses)::integer AS losses,
 (base_md3+new_md3)::integer AS md3,
 (base_md5+new_md5)::integer AS md5,
 (base_points+new_points)::numeric(12,1) AS points,
 CASE WHEN base_games+new_games=0 THEN 0
 ELSE round(100.0*(base_wins+new_wins)/(base_games+new_games),1) END AS winrate
FROM counted;
GRANT SELECT ON public.scrim_ranking TO authenticated;

-- In House individual: resultados e classificação independentes dos times.
CREATE TABLE IF NOT EXISTS public.inhouse_matches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 player_a uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 player_b uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 match_format text NOT NULL DEFAULT 'MD3' CHECK(match_format IN ('MD1','MD3','MD5')),
 scheduled_at timestamptz,
 status text NOT NULL DEFAULT 'AGENDADA' CHECK(status IN ('AGENDADA','CONFIRMADA','FINALIZADA','CANCELADA')),
 score_a integer NOT NULL DEFAULT 0 CHECK(score_a>=0),
 score_b integer NOT NULL DEFAULT 0 CHECK(score_b>=0),
 created_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT inhouse_match_distinct_v3 CHECK(player_a<>player_b)
);
ALTER TABLE public.inhouse_matches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inhouse_matches FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.inhouse_matches TO authenticated;
DROP POLICY IF EXISTS inhouse_matches_read_v3 ON public.inhouse_matches;
CREATE POLICY inhouse_matches_read_v3 ON public.inhouse_matches FOR SELECT TO authenticated USING(true);
DROP POLICY IF EXISTS inhouse_matches_admin_v3 ON public.inhouse_matches;
CREATE POLICY inhouse_matches_admin_v3 ON public.inhouse_matches FOR ALL TO authenticated
USING(public.has_permission('all')) WITH CHECK(public.has_permission('all'));

CREATE OR REPLACE VIEW public.inhouse_ranking WITH (security_invoker=true) AS
WITH results AS (
 SELECT m.player_a AS player_id,m.match_format,m.score_a AS pf,m.score_b AS pa
 FROM public.inhouse_matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b
 UNION ALL
 SELECT m.player_b AS player_id,m.match_format,m.score_b AS pf,m.score_a AS pa
 FROM public.inhouse_matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b
)
SELECT p.id AS player_id,
 count(r.player_id)::integer AS games,
 count(r.player_id) FILTER(WHERE r.pf>r.pa)::integer AS wins,
 count(r.player_id) FILTER(WHERE r.pf<r.pa)::integer AS losses,
 count(r.player_id) FILTER(WHERE r.match_format='MD3')::integer AS md3,
 count(r.player_id) FILTER(WHERE r.match_format='MD5')::integer AS md5,
 COALESCE(sum(public.olympus_series_points(r.pf>r.pa,r.match_format,r.pf,r.pa)),0)::numeric(12,1) AS points,
 CASE WHEN count(r.player_id)=0 THEN 0 ELSE round(100.0*count(r.player_id) FILTER(WHERE r.pf>r.pa)/count(r.player_id),1) END AS winrate
FROM public.profiles p LEFT JOIN results r ON r.player_id=p.id
GROUP BY p.id;
GRANT SELECT ON public.inhouse_ranking TO authenticated;

-- Notícias com imagem: upload permitido somente a jornalistas autorizados ou ADMs.
ALTER TABLE public.news ADD COLUMN IF NOT EXISTS image_url text;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('news-images','news-images',true,5242880,array['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO UPDATE SET public=true,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
DROP POLICY IF EXISTS olympus_news_image_read_v3 ON storage.objects;
CREATE POLICY olympus_news_image_read_v3 ON storage.objects FOR SELECT TO anon,authenticated
USING(bucket_id='news-images');
DROP POLICY IF EXISTS olympus_news_image_upload_v3 ON storage.objects;
CREATE POLICY olympus_news_image_upload_v3 ON storage.objects FOR INSERT TO authenticated
WITH CHECK(bucket_id='news-images' AND (storage.foldername(name))[1]=auth.uid()::text AND public.has_permission('news_create'));
-- Evitar substituição de imagem de outra pessoa via upsert.

-- Provas de reports em bucket PRIVADO: somente denunciante e ADM podem ler.
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('report-evidence','report-evidence',false,5242880,array['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
CREATE TABLE IF NOT EXISTS public.report_evidence (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 report_id uuid NOT NULL REFERENCES public.reports(id) ON DELETE CASCADE,
 uploaded_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 storage_path text NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.report_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.report_evidence FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON public.report_evidence TO authenticated;
DROP POLICY IF EXISTS olympus_report_evidence_read_v3 ON public.report_evidence;
CREATE POLICY olympus_report_evidence_read_v3 ON public.report_evidence FOR SELECT TO authenticated
USING(public.has_permission('all') OR uploaded_by=auth.uid());
DROP POLICY IF EXISTS olympus_report_evidence_insert_v3 ON public.report_evidence;
CREATE POLICY olympus_report_evidence_insert_v3 ON public.report_evidence FOR INSERT TO authenticated
WITH CHECK(uploaded_by=auth.uid() AND split_part(storage_path,'/',1)=auth.uid()::text
  AND EXISTS(SELECT 1 FROM public.reports r WHERE r.id=report_id AND r.reporter_id=auth.uid() AND r.status='ABERTO'));
DROP POLICY IF EXISTS olympus_report_storage_read_v3 ON storage.objects;
CREATE POLICY olympus_report_storage_read_v3 ON storage.objects FOR SELECT TO authenticated
USING(bucket_id='report-evidence' AND (public.has_permission('all') OR (storage.foldername(name))[1]=auth.uid()::text));
DROP POLICY IF EXISTS olympus_report_storage_upload_v3 ON storage.objects;
CREATE POLICY olympus_report_storage_upload_v3 ON storage.objects FOR INSERT TO authenticated
WITH CHECK(bucket_id='report-evidence' AND (storage.foldername(name))[1]=auth.uid()::text);

-- Privilégios SQL explícitos para tabelas antigas, sem torná-las públicas.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON public.teams,public.team_stats,public.team_members,public.profiles,public.roles,public.matches,public.news,public.reports TO authenticated;
GRANT SELECT ON public.scrim_invites,public.inhouse_matches,public.inhouse_ranking,public.scrim_ranking,public.scrim_legacy_stats,public.report_evidence TO authenticated;
-- Desfazer GRANT público abrangente caso ele tenha sido aplicado no passado.
-- Notícias publicadas podem continuar com leitura pública por política separada.
REVOKE ALL ON public.profiles,public.roles,public.team_members,public.team_stats,
 public.reports,public.report_evidence,public.scrim_invites,public.scrim_legacy_stats,
 public.matches,public.inhouse_matches FROM anon;
GRANT INSERT ON public.reports TO authenticated;
COMMIT;
-- Atualizar o cache de metadados do PostgREST para disponibilizar tabelas e RPCs.
NOTIFY pgrst, 'reload schema';
