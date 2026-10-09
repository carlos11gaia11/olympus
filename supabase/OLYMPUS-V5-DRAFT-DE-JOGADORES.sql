-- OLYMPUS V5: DRAFT DE JOGADORES (não campeões)
-- Executar APÓS OLYMPUS-V4-INHOUSE-FILAS-DRAFT.sql.
-- Não apaga dados nem partidas. Partidas que estejam em DRAFT da V4 devem ser
-- concluídas ou canceladas ANTES desta migração (a lógica antiga deixa de existir).
BEGIN;

ALTER TABLE public.inhouse_lobbies
 ADD COLUMN IF NOT EXISTS captain_a uuid REFERENCES public.profiles(id),
 ADD COLUMN IF NOT EXISTS captain_b uuid REFERENCES public.profiles(id),
 ADD COLUMN IF NOT EXISTS captain_role text;
ALTER TABLE public.inhouse_queue_entries ADD COLUMN IF NOT EXISTS draft_side text;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ih_draft_side_valid_v5' AND conrelid='public.inhouse_queue_entries'::regclass) THEN
  ALTER TABLE public.inhouse_queue_entries ADD CONSTRAINT ih_draft_side_valid_v5 CHECK(draft_side IS NULL OR draft_side IN('A','B'));
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ih_captain_role_valid_v5' AND conrelid='public.inhouse_lobbies'::regclass) THEN
  ALTER TABLE public.inhouse_lobbies ADD CONSTRAINT ih_captain_role_valid_v5 CHECK(captain_role IS NULL OR captain_role IN('Top','Jungle','Mid','ADC','Support'));
 END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.inhouse_player_draft_picks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 lobby_id uuid NOT NULL REFERENCES public.inhouse_lobbies(id) ON DELETE CASCADE,
 turn integer NOT NULL CHECK(turn BETWEEN 0 AND 3),
 captain_id uuid NOT NULL REFERENCES public.profiles(id),
 captain_side text NOT NULL CHECK(captain_side IN('A','B')),
 chosen_player_id uuid NOT NULL REFERENCES public.profiles(id),
 paired_player_id uuid NOT NULL REFERENCES public.profiles(id),
 role text NOT NULL CHECK(role IN('Top','Jungle','Mid','ADC','Support')),
 automatic boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(lobby_id,turn),
 UNIQUE(lobby_id,role),
 UNIQUE(lobby_id,chosen_player_id),
 UNIQUE(lobby_id,paired_player_id),
 CHECK(chosen_player_id<>paired_player_id)
);
ALTER TABLE public.inhouse_player_draft_picks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inhouse_player_draft_picks FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.inhouse_player_draft_picks TO authenticated;
DROP POLICY IF EXISTS ih_player_draft_read_v5 ON public.inhouse_player_draft_picks;
CREATE POLICY ih_player_draft_read_v5 ON public.inhouse_player_draft_picks
 FOR SELECT TO authenticated USING(true);

-- A função de confirmação escolhe automaticamente DOIS capitães da MESMA FUNÇÃO.
-- Cada um inicia em um time diferente. Os outros 8 aguardam o draft.
CREATE OR REPLACE FUNCTION public.inhouse_confirm(p_lobby_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_count int; v_total int;
 v_role text; v_ca uuid; v_cb uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'AGENDADA' THEN RAISE EXCEPTION 'Confirmação indisponível'; END IF;
 IF now()<l.confirm_at THEN RAISE EXCEPTION 'Aguarde o horário de confirmação'; END IF;
 UPDATE public.inhouse_queue_entries SET status='CONFIRMED',confirmed_at=now()
 WHERE lobby_id=l.id AND player_id=auth.uid() AND status='SLOT';
 IF NOT FOUND THEN RAISE EXCEPTION 'Você deve estar em uma das dez vagas'; END IF;
 SELECT count(*) INTO v_total FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND status IN('SLOT','CONFIRMED');
 SELECT count(*) INTO v_count FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND status='CONFIRMED';
 IF v_total=10 AND v_count=10 AND
  (SELECT count(DISTINCT role) FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND status='CONFIRMED')=5 THEN
  SELECT role INTO v_role FROM public.inhouse_queue_entries
    WHERE lobby_id=l.id AND status='CONFIRMED'
    GROUP BY role HAVING count(*)=2 ORDER BY random() LIMIT 1;
  SELECT player_id INTO v_ca FROM public.inhouse_queue_entries
    WHERE lobby_id=l.id AND role=v_role AND side='A' AND status='CONFIRMED';
  SELECT player_id INTO v_cb FROM public.inhouse_queue_entries
    WHERE lobby_id=l.id AND role=v_role AND side='B' AND status='CONFIRMED';
  IF v_ca IS NULL OR v_cb IS NULL THEN RAISE EXCEPTION 'Não foi possível selecionar capitães'; END IF;
  UPDATE public.inhouse_queue_entries SET draft_side=
    CASE WHEN player_id=v_ca THEN 'A' WHEN player_id=v_cb THEN 'B' ELSE NULL END
  WHERE lobby_id=l.id;
  UPDATE public.inhouse_lobbies SET status='DRAFT',draft_step=0,
    captain_a=v_ca,captain_b=v_cb,captain_role=v_role,
    draft_deadline=now()+interval '20 seconds' WHERE id=l.id;
  RETURN 'DRAFT';
 END IF;
 RETURN 'CONFIRMED';
END $$;

-- AUXILIAR DE ESCRITA TRANSACIONAL: chamado apenas por picks/timeout verificados.
CREATE OR REPLACE FUNCTION public.inhouse_player_draft_apply(
 p_lobby_id uuid,p_player_id uuid,p_automatic boolean DEFAULT false)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_side text; v_captain uuid;
 v_role text; v_pair uuid;
BEGIN
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'DRAFT' OR l.draft_step NOT BETWEEN 0 AND 3 THEN
   RAISE EXCEPTION 'Draft indisponível'; END IF;
 v_side:=CASE WHEN mod(l.draft_step,2)=0 THEN 'A' ELSE 'B' END;
 v_captain:=CASE WHEN v_side='A' THEN l.captain_a ELSE l.captain_b END;
 IF v_captain IS NULL THEN RAISE EXCEPTION 'Capitão ausente'; END IF;
 SELECT role INTO v_role FROM public.inhouse_queue_entries
 WHERE lobby_id=l.id AND player_id=p_player_id AND status='CONFIRMED' AND draft_side IS NULL;
 IF v_role IS NULL OR v_role=l.captain_role THEN
  RAISE EXCEPTION 'Jogador indisponível para a escolha'; END IF;
 SELECT player_id INTO v_pair FROM public.inhouse_queue_entries
 WHERE lobby_id=l.id AND role=v_role AND status='CONFIRMED'
  AND draft_side IS NULL AND player_id<>p_player_id;
 IF v_pair IS NULL OR
   (SELECT count(*) FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND role=v_role AND status='CONFIRMED' AND draft_side IS NULL)<>2 THEN
   RAISE EXCEPTION 'Par de função inválido ou já escolhido'; END IF;
 UPDATE public.inhouse_queue_entries
 SET draft_side=CASE WHEN player_id=p_player_id THEN v_side
                     ELSE CASE WHEN v_side='A' THEN 'B' ELSE 'A' END END
 WHERE lobby_id=l.id AND player_id IN(p_player_id,v_pair) AND draft_side IS NULL;
 IF (SELECT count(*) FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND role=v_role AND draft_side IS NOT NULL)<>2 THEN
  RAISE EXCEPTION 'Não foi possível distribuir o par'; END IF;
 INSERT INTO public.inhouse_player_draft_picks(lobby_id,turn,captain_id,captain_side,
  chosen_player_id,paired_player_id,role,automatic)
 VALUES(l.id,l.draft_step,v_captain,v_side,p_player_id,v_pair,v_role,p_automatic);
 IF l.draft_step=3 THEN
  IF (SELECT count(*) FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND status='CONFIRMED' AND draft_side IN('A','B'))<>10 OR
     (SELECT count(*) FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND status='CONFIRMED' AND draft_side='A')<>5 OR
     (SELECT count(*) FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND status='CONFIRMED' AND draft_side='B')<>5 THEN
   RAISE EXCEPTION 'Formação final inválida'; END IF;
  UPDATE public.inhouse_lobbies SET draft_step=4,status='EM_JOGO',draft_deadline=NULL WHERE id=l.id;
 ELSE
  UPDATE public.inhouse_lobbies SET draft_step=l.draft_step+1,
   draft_deadline=now()+interval '20 seconds' WHERE id=l.id;
 END IF;
 RETURN l.draft_step+1;
END $$;
REVOKE ALL ON FUNCTION public.inhouse_player_draft_apply(uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.inhouse_pick_player(p_lobby_id uuid,p_player_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_captain uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'DRAFT' THEN RAISE EXCEPTION 'Draft indisponível'; END IF;
 IF now()>=l.draft_deadline THEN RAISE EXCEPTION '20 segundos encerrados; aguarde a escolha automática'; END IF;
 v_captain:=CASE WHEN mod(l.draft_step,2)=0 THEN l.captain_a ELSE l.captain_b END;
 IF v_captain IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Apenas o capitão da vez pode escolher'; END IF;
 RETURN public.inhouse_player_draft_apply(p_lobby_id,p_player_id,false);
END $$;

-- Idempotente sob concorrência: prazo e etapa verificados sob lock da sala.
CREATE OR REPLACE FUNCTION public.inhouse_advance_player_draft(p_lobby_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_player uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sala inexistente'; END IF;
 IF l.status<>'DRAFT' OR now()<l.draft_deadline THEN RETURN l.draft_step; END IF;
 SELECT player_id INTO v_player FROM public.inhouse_queue_entries
 WHERE lobby_id=l.id AND status='CONFIRMED' AND draft_side IS NULL
 ORDER BY joined_at,player_id LIMIT 1;
 IF v_player IS NULL THEN RAISE EXCEPTION 'Não há jogadores para a escolha automática'; END IF;
 RETURN public.inhouse_player_draft_apply(p_lobby_id,v_player,true);
END $$;

-- Fecha a rota antiga: ninguém poderá chamar o draft de campeões anterior.
REVOKE ALL ON FUNCTION public.inhouse_draft_move(uuid,text),
 public.inhouse_advance_draft(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.inhouse_pick_player(uuid,uuid),
 public.inhouse_advance_player_draft(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.inhouse_pick_player(uuid,uuid),
 public.inhouse_advance_player_draft(uuid) TO authenticated;

-- Corrige a pontuação: as equipes oficiais são as do DRAFT, não as vagas provisórias de fila.
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
 coalesce(sum(public.olympus_series_points(r.pf>r.pa,r.match_format,r.pf,r.pa)),0)::numeric(12,1) AS points,
 CASE WHEN count(r.player_id)=0 THEN 0
 ELSE round(100.0*count(r.player_id) FILTER(WHERE r.pf>r.pa)/count(r.player_id),1) END AS winrate
FROM public.profiles p LEFT JOIN results r ON r.player_id=p.id
GROUP BY p.id;
GRANT SELECT ON public.inhouse_ranking TO authenticated;
COMMIT;
NOTIFY pgrst,'reload schema';
