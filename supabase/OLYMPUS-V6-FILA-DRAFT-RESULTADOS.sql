-- OLYMPUS V6 | FILA + CONFIRMACAO DE RESULTADO + RANKING
-- Execute depois da V5. Nao apaga partidas ou pontuacoes anteriores.
-- Seguranca: registrar placar nao finaliza a partida; requer 5 ACEITES distintos.
BEGIN;

ALTER TABLE public.inhouse_lobbies
  ADD COLUMN IF NOT EXISTS proposed_winner_side text,
  ADD COLUMN IF NOT EXISTS proposed_loser_games integer,
  ADD COLUMN IF NOT EXISTS result_proposed_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS result_proposed_at timestamptz,
  ADD COLUMN IF NOT EXISTS result_version integer NOT NULL DEFAULT 0;

DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ih6_proposed_winner') THEN
  ALTER TABLE public.inhouse_lobbies ADD CONSTRAINT ih6_proposed_winner
   CHECK(proposed_winner_side IS NULL OR proposed_winner_side IN ('A','B'));
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ih6_proposed_games') THEN
  ALTER TABLE public.inhouse_lobbies ADD CONSTRAINT ih6_proposed_games
   CHECK(proposed_loser_games IS NULL OR proposed_loser_games IN (0,1));
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='ih6_proposal_complete') THEN
  ALTER TABLE public.inhouse_lobbies ADD CONSTRAINT ih6_proposal_complete
   CHECK ((proposed_winner_side IS NULL) = (proposed_loser_games IS NULL));
 END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.inhouse_result_confirmations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 lobby_id uuid NOT NULL REFERENCES public.inhouse_lobbies(id) ON DELETE CASCADE,
 player_id uuid NOT NULL REFERENCES public.profiles(id),
 proposal_version integer NOT NULL,
 agree boolean NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(lobby_id,player_id)
);
ALTER TABLE public.inhouse_result_confirmations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inhouse_result_confirmations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.inhouse_result_confirmations TO authenticated;
DROP POLICY IF EXISTS ih6_result_confirmations_read ON public.inhouse_result_confirmations;
CREATE POLICY ih6_result_confirmations_read ON public.inhouse_result_confirmations
 FOR SELECT TO authenticated USING (true);

-- Jogadores confirmados podem lancar um placar inicial. Alteracoes subsequentes
-- sao permitidas ao lancador, aos capitaes e aos administradores.
CREATE OR REPLACE FUNCTION public.inhouse_propose_result(
 p_lobby_id uuid,p_winner_side text,p_loser_games integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_admin boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faca login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'EM_JOGO' OR l.captain_a IS NULL OR l.captain_b IS NULL
  THEN RAISE EXCEPTION 'Resultado disponivel somente apos o draft de jogadores'; END IF;
 IF p_winner_side IS NULL OR p_winner_side NOT IN ('A','B') OR p_loser_games IS NULL OR p_loser_games NOT IN (0,1)
  THEN RAISE EXCEPTION 'Placar MD3 invalido'; END IF;
 v_admin:=public.has_permission('all');
 IF NOT v_admin AND NOT EXISTS(
  SELECT 1 FROM public.inhouse_queue_entries
  WHERE lobby_id=l.id AND player_id=auth.uid() AND status='CONFIRMED' AND draft_side IN ('A','B'))
  THEN RAISE EXCEPTION 'Somente participantes confirmados ou ADM podem lancar resultado'; END IF;
 IF l.proposed_winner_side IS NOT NULL AND NOT v_admin
  AND auth.uid() IS DISTINCT FROM l.result_proposed_by
  AND auth.uid() IS DISTINCT FROM l.captain_a
  AND auth.uid() IS DISTINCT FROM l.captain_b
  THEN RAISE EXCEPTION 'Apenas quem lancou, um capitao ou ADM pode corrigir o placar'; END IF;
 -- Enviar novamente o mesmo placar nao zera confirmacoes recebidas.
 IF l.proposed_winner_side IS NOT DISTINCT FROM p_winner_side
  AND l.proposed_loser_games IS NOT DISTINCT FROM p_loser_games THEN
  RETURN l.result_version;
 END IF;
 UPDATE public.inhouse_lobbies SET
  proposed_winner_side=p_winner_side,proposed_loser_games=p_loser_games,
  result_proposed_by=auth.uid(),result_proposed_at=now(),
  result_version=result_version+1
 WHERE id=l.id RETURNING result_version INTO l.result_version;
 DELETE FROM public.inhouse_result_confirmations WHERE lobby_id=l.id;
 RETURN l.result_version;
END $$;

-- Cada participante confirmado pode concordar/discordar exatamente uma vez por
-- versao do placar (pode alterar a escolha). A 5a concordancia fecha a partida
-- atomicamente e atualiza a view existente public.inhouse_ranking.
CREATE OR REPLACE FUNCTION public.inhouse_confirm_result(p_lobby_id uuid,p_agree boolean)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_count integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faca login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'EM_JOGO' OR l.proposed_winner_side IS NULL
  THEN RAISE EXCEPTION 'Ainda nao existe resultado pendente de confirmacao'; END IF;
 IF p_agree IS NULL THEN RAISE EXCEPTION 'Confirmacao invalida'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.inhouse_queue_entries
  WHERE lobby_id=l.id AND player_id=auth.uid() AND status='CONFIRMED' AND draft_side IN ('A','B'))
  THEN RAISE EXCEPTION 'Somente participantes confirmados podem confirmar'; END IF;
 INSERT INTO public.inhouse_result_confirmations(lobby_id,player_id,proposal_version,agree)
 VALUES(l.id,auth.uid(),l.result_version,p_agree)
 ON CONFLICT(lobby_id,player_id) DO UPDATE
 SET proposal_version=excluded.proposal_version,agree=excluded.agree,created_at=now();
 SELECT count(*) INTO v_count FROM public.inhouse_result_confirmations
 WHERE lobby_id=l.id AND proposal_version=l.result_version AND agree=true;
 IF v_count>=5 THEN
  UPDATE public.inhouse_lobbies SET
   status='FINALIZADA',winner_side=l.proposed_winner_side,
   score_a=CASE WHEN l.proposed_winner_side='A' THEN 2 ELSE l.proposed_loser_games END,
   score_b=CASE WHEN l.proposed_winner_side='B' THEN 2 ELSE l.proposed_loser_games END
  WHERE id=l.id AND status='EM_JOGO';
 END IF;
 RETURN v_count;
END $$;

-- Nao deixar clientes antigos finalizarem via votos de placares divergentes.
REVOKE ALL ON FUNCTION public.inhouse_vote_result(uuid,text,integer)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.inhouse_propose_result(uuid,text,integer),
 public.inhouse_confirm_result(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.inhouse_propose_result(uuid,text,integer),
 public.inhouse_confirm_result(uuid,boolean) TO authenticated;

-- Corrige tambem o caso do perfil com funcao Flex em filas sem fill habilitado.
CREATE OR REPLACE FUNCTION public.inhouse_join(p_lobby_id uuid,p_role text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; p_role_registered text;v_side text;v_status text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faca login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Partida inexistente'; END IF;
 IF l.status<>'AGENDADA' OR now()<l.queue_open_at
  THEN RAISE EXCEPTION 'Inscricoes encerradas ou fila ainda nao aberta'; END IF;
 IF p_role IS NULL OR p_role NOT IN ('Top','Jungle','Mid','ADC','Support') THEN RAISE EXCEPTION 'Funcao invalida'; END IF;
 SELECT lol_role INTO p_role_registered FROM public.profiles WHERE id=auth.uid();
 IF NOT l.allow_fill AND lower(trim(coalesce(p_role_registered,''))) NOT IN (lower(p_role),'flex')
  THEN RAISE EXCEPTION 'Escolha a funcao cadastrada no perfil ou solicite fill'; END IF;
 IF EXISTS(SELECT 1 FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND player_id=auth.uid())
  THEN RAISE EXCEPTION 'Voce ja esta nesta fila'; END IF;
 SELECT side INTO v_side FROM (VALUES('A'),('B')) AS sides(side)
 WHERE NOT EXISTS(SELECT 1 FROM public.inhouse_queue_entries e WHERE e.lobby_id=l.id AND e.role=p_role
  AND e.side=sides.side AND e.status IN('SLOT','CONFIRMED'))
 ORDER BY side LIMIT 1;
 IF v_side IS NULL THEN v_status:='WAITING'; ELSE v_status:='SLOT'; END IF;
 INSERT INTO public.inhouse_queue_entries(lobby_id,player_id,role,side,status)
 VALUES(l.id,auth.uid(),p_role,v_side,v_status);
 RETURN v_status;
END $$;

-- Evita ranking usando side provisoria em novas partidas finalizadas:
-- a view V5 ja utiliza coalesce(draft_side,side) e e atualizada automaticamente.
-- Sem contagem dupla: cada lobby finalizado entra exatamente uma vez por participante.
COMMIT;
NOTIFY pgrst,'reload schema';
