-- OLYMPUS V4 · IN HOUSE 5x5 · Executar APÓS OLYMPUS-V3-INHOUSE-SCRIMS.sql
-- Mantém dados e partidas individuais antigas. Escritas sensíveis ocorrem somente por RPCs.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.inhouse_lobbies (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 3 AND 100),
 queue_open_at timestamptz NOT NULL,
 confirm_at timestamptz NOT NULL,
 allow_fill boolean NOT NULL DEFAULT false,
 match_format text NOT NULL DEFAULT 'MD3' CHECK(match_format='MD3'),
 status text NOT NULL DEFAULT 'AGENDADA' CHECK(status IN('AGENDADA','DRAFT','EM_JOGO','FINALIZADA','CANCELADA')),
 draft_step integer NOT NULL DEFAULT 0 CHECK(draft_step BETWEEN 0 AND 20),
 draft_deadline timestamptz,
 winner_side text CHECK(winner_side IN('A','B')),
 score_a integer CHECK(score_a IN(0,1,2)),
 score_b integer CHECK(score_b IN(0,1,2)),
 created_by uuid NOT NULL REFERENCES public.profiles(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(confirm_at>queue_open_at),
 CHECK(status<>'FINALIZADA' OR (winner_side IS NOT NULL AND greatest(score_a,score_b)=2 AND least(score_a,score_b) IN(0,1)))
);
CREATE INDEX IF NOT EXISTS inhouse_lobbies_dates_idx ON public.inhouse_lobbies(queue_open_at DESC);
CREATE TABLE IF NOT EXISTS public.inhouse_queue_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 lobby_id uuid NOT NULL REFERENCES public.inhouse_lobbies(id) ON DELETE CASCADE,
 player_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
 role text NOT NULL CHECK(role IN('Top','Jungle','Mid','ADC','Support')),
 side text CHECK(side IN('A','B')),
 status text NOT NULL CHECK(status IN('WAITING','SLOT','CONFIRMED')),
 joined_at timestamptz NOT NULL DEFAULT now(),
 confirmed_at timestamptz,
 UNIQUE(lobby_id,player_id),
 CHECK((status='WAITING' AND side IS NULL) OR (status IN('SLOT','CONFIRMED') AND side IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS inhouse_slot_one_per_role_side ON public.inhouse_queue_entries(lobby_id,role,side) WHERE status IN('SLOT','CONFIRMED');
CREATE INDEX IF NOT EXISTS inhouse_wait_order_idx ON public.inhouse_queue_entries(lobby_id,role,joined_at) WHERE status='WAITING';
CREATE TABLE IF NOT EXISTS public.inhouse_champions (
 name text PRIMARY KEY CHECK(length(name) BETWEEN 2 AND 40)
);
CREATE TABLE IF NOT EXISTS public.inhouse_draft_actions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 lobby_id uuid NOT NULL REFERENCES public.inhouse_lobbies(id) ON DELETE CASCADE,
 turn integer NOT NULL CHECK(turn BETWEEN 0 AND 19),
 player_id uuid NOT NULL REFERENCES public.profiles(id),
 side text NOT NULL CHECK(side IN('A','B')),
 action text NOT NULL CHECK(action IN('BAN','PICK')),
 champion text REFERENCES public.inhouse_champions(name),
 automatic boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(lobby_id,turn),
 CHECK(action='BAN' OR champion IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS inhouse_unique_champion ON public.inhouse_draft_actions(lobby_id,lower(champion)) WHERE champion IS NOT NULL;
CREATE TABLE IF NOT EXISTS public.inhouse_result_votes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 lobby_id uuid NOT NULL REFERENCES public.inhouse_lobbies(id) ON DELETE CASCADE,
 voter_id uuid NOT NULL REFERENCES public.profiles(id),
 winner_side text NOT NULL CHECK(winner_side IN('A','B')),
 loser_games integer NOT NULL CHECK(loser_games IN(0,1)),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(lobby_id,voter_id)
);

-- Catálogo offline da seleção. Pode ser ampliado futuramente pelo ADM no SQL.
INSERT INTO public.inhouse_champions(name) VALUES
 ('Aatrox'),('Ahri'),('Akali'),('Akshan'),('Alistar'),('Amumu'),('Anivia'),('Annie'),('Aphelios'),('Ashe'),
 ('Aurelion Sol'),('Azir'),('Bard'),('Bel''Veth'),('Blitzcrank'),('Brand'),('Braum'),('Briar'),('Caitlyn'),('Camille'),
 ('Cassiopeia'),('Cho''Gath'),('Corki'),('Darius'),('Diana'),('Dr. Mundo'),('Draven'),('Ekko'),('Elise'),('Evelynn'),
 ('Ezreal'),('Fiddlesticks'),('Fiora'),('Fizz'),('Galio'),('Gangplank'),('Garen'),('Gnar'),('Gragas'),('Graves'),
 ('Gwen'),('Hecarim'),('Heimerdinger'),('Hwei'),('Illaoi'),('Irelia'),('Ivern'),('Janna'),('Jarvan IV'),('Jax'),
 ('Jayce'),('Jhin'),('Jinx'),('K''Sante'),('Kai''Sa'),('Kalista'),('Karma'),('Karthus'),('Kassadin'),('Katarina'),
 ('Kayle'),('Kayn'),('Kennen'),('Kha''Zix'),('Kindred'),('Kled'),('Kog''Maw'),('LeBlanc'),('Lee Sin'),('Leona'),
 ('Lillia'),('Lissandra'),('Lucian'),('Lulu'),('Lux'),('Malphite'),('Malzahar'),('Maokai'),('Master Yi'),('Milio'),
 ('Miss Fortune'),('Mordekaiser'),('Morgana'),('Naafiri'),('Nami'),('Nasus'),('Nautilus'),('Neeko'),('Nidalee'),('Nilah'),
 ('Nocturne'),('Nunu e Willump'),('Olaf'),('Orianna'),('Ornn'),('Pantheon'),('Poppy'),('Pyke'),('Qiyana'),('Quinn'),
 ('Rakan'),('Rammus'),('Rek''Sai'),('Rell'),('Renata Glasc'),('Renekton'),('Rengar'),('Riven'),('Rumble'),('Ryze'),
 ('Samira'),('Sejuani'),('Senna'),('Seraphine'),('Sett'),('Shaco'),('Shen'),('Shyvana'),('Singed'),('Sion'),
 ('Sivir'),('Skarner'),('Smolder'),('Sona'),('Soraka'),('Swain'),('Sylas'),('Syndra'),('Tahm Kench'),('Taliyah'),
 ('Talon'),('Taric'),('Teemo'),('Thresh'),('Tristana'),('Trundle'),('Tryndamere'),('Twisted Fate'),('Twitch'),('Udyr'),
 ('Urgot'),('Varus'),('Vayne'),('Veigar'),('Vel''Koz'),('Vex'),('Vi'),('Viego'),('Viktor'),('Vladimir'),
 ('Volibear'),('Warwick'),('Wukong'),('Xayah'),('Xerath'),('Xin Zhao'),('Yasuo'),('Yone'),('Yorick'),('Yuumi'),
 ('Zac'),('Zed'),('Zeri'),('Ziggs'),('Zilean'),('Zoe'),('Zyra')
ON CONFLICT(name) DO NOTHING;

-- Segurança: SELECT para sessões autenticadas e mutações exclusivamente nas RPCs.
ALTER TABLE public.inhouse_lobbies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inhouse_queue_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inhouse_draft_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inhouse_result_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inhouse_champions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inhouse_lobbies, public.inhouse_queue_entries, public.inhouse_draft_actions,
 public.inhouse_result_votes, public.inhouse_champions FROM PUBLIC,anon,authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON public.inhouse_lobbies, public.inhouse_queue_entries, public.inhouse_draft_actions,
 public.inhouse_result_votes, public.inhouse_champions TO authenticated;
DROP POLICY IF EXISTS ih_lobbies_read_v4 ON public.inhouse_lobbies;
DROP POLICY IF EXISTS ih_entries_read_v4 ON public.inhouse_queue_entries;
DROP POLICY IF EXISTS ih_actions_read_v4 ON public.inhouse_draft_actions;
DROP POLICY IF EXISTS ih_votes_read_v4 ON public.inhouse_result_votes;
DROP POLICY IF EXISTS ih_champions_read_v4 ON public.inhouse_champions;
CREATE POLICY ih_lobbies_read_v4 ON public.inhouse_lobbies FOR SELECT TO authenticated USING(true);
CREATE POLICY ih_entries_read_v4 ON public.inhouse_queue_entries FOR SELECT TO authenticated USING(true);
CREATE POLICY ih_actions_read_v4 ON public.inhouse_draft_actions FOR SELECT TO authenticated USING(true);
CREATE POLICY ih_votes_read_v4 ON public.inhouse_result_votes FOR SELECT TO authenticated USING(true);
CREATE POLICY ih_champions_read_v4 ON public.inhouse_champions FOR SELECT TO authenticated USING(true);

CREATE OR REPLACE FUNCTION public.inhouse_create_lobby(p_title text,p_queue_open_at timestamptz,p_confirm_at timestamptz,p_allow_fill boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_permission('all') THEN RAISE EXCEPTION 'Somente ADM pode criar partidas'; END IF;
 IF trim(coalesce(p_title,''))='' OR length(trim(p_title))>100 THEN RAISE EXCEPTION 'Título inválido'; END IF;
 IF p_queue_open_at IS NULL OR p_confirm_at IS NULL OR p_confirm_at<=p_queue_open_at OR p_confirm_at<=now() THEN RAISE EXCEPTION 'Informe abertura da fila antes do início da confirmação (no futuro)'; END IF;
 INSERT INTO public.inhouse_lobbies(title,queue_open_at,confirm_at,allow_fill,created_by)
 VALUES(trim(p_title),p_queue_open_at,p_confirm_at,coalesce(p_allow_fill,false),auth.uid()) RETURNING id INTO v_id;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.inhouse_admin_update(p_lobby_id uuid,p_title text,p_queue_open_at timestamptz,p_confirm_at timestamptz,p_allow_fill boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_permission('all') THEN RAISE EXCEPTION 'Acesso negado'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Partida inexistente'; END IF;
 IF l.status<>'AGENDADA' OR EXISTS(SELECT 1 FROM public.inhouse_queue_entries WHERE lobby_id=l.id) THEN
 RAISE EXCEPTION 'Só é possível editar antes de jogadores entrarem'; END IF;
 IF length(trim(coalesce(p_title,''))) NOT BETWEEN 3 AND 100 OR p_queue_open_at IS NULL OR p_confirm_at<=p_queue_open_at OR p_confirm_at<=now() THEN RAISE EXCEPTION 'Dados de agendamento inválidos'; END IF;
 UPDATE public.inhouse_lobbies SET title=trim(p_title),queue_open_at=p_queue_open_at,confirm_at=p_confirm_at,allow_fill=coalesce(p_allow_fill,false) WHERE id=l.id;
END $$;

-- Auxiliar de promoção; chamada apenas por funções autorizadas (sem GRANT ao cliente).
CREATE OR REPLACE FUNCTION public.inhouse_promote_waiting(p_lobby_id uuid,p_role text,p_side text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id uuid;
BEGIN
 SELECT id INTO v_id FROM public.inhouse_queue_entries
 WHERE lobby_id=p_lobby_id AND role=p_role AND status='WAITING'
 ORDER BY joined_at,id LIMIT 1 FOR UPDATE;
 IF v_id IS NOT NULL THEN
 UPDATE public.inhouse_queue_entries SET status='SLOT',side=p_side,confirmed_at=NULL WHERE id=v_id;
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.inhouse_promote_waiting(uuid,text,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.inhouse_join(p_lobby_id uuid,p_role text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; p_role_registered text;v_side text; v_status text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Partida inexistente'; END IF;
 IF l.status<>'AGENDADA' OR now()<l.queue_open_at THEN RAISE EXCEPTION 'Fila ainda não abriu ou partida já começou'; END IF;
 IF p_role NOT IN ('Top','Jungle','Mid','ADC','Support') OR p_role IS NULL THEN RAISE EXCEPTION 'Função inválida'; END IF;
 SELECT lol_role INTO p_role_registered FROM public.profiles WHERE id=auth.uid();
 IF NOT l.allow_fill AND p_role IS DISTINCT FROM p_role_registered THEN RAISE EXCEPTION 'Você só pode entrar na função cadastrada no seu perfil'; END IF;
 IF EXISTS(SELECT 1 FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND player_id=auth.uid()) THEN RAISE EXCEPTION 'Você já está nesta fila'; END IF;
 -- Reservar a primeira vaga livre, priorizando a ordem de entrada.
 SELECT side INTO v_side FROM (VALUES('A'),('B')) AS sides(side)
 WHERE NOT EXISTS(SELECT 1 FROM public.inhouse_queue_entries e WHERE e.lobby_id=l.id AND e.role=p_role AND e.side=sides.side AND e.status IN('SLOT','CONFIRMED'))
 ORDER BY side LIMIT 1;
 IF v_side IS NULL THEN v_status:='WAITING'; ELSE v_status:='SLOT'; END IF;
 INSERT INTO public.inhouse_queue_entries(lobby_id,player_id,role,side,status) VALUES(l.id,auth.uid(),p_role,v_side,v_status);
 RETURN v_status;
END $$;

CREATE OR REPLACE FUNCTION public.inhouse_leave(p_lobby_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; e public.inhouse_queue_entries%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'AGENDADA' THEN RAISE EXCEPTION 'Não é possível sair após o início do draft'; END IF;
 SELECT * INTO e FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND player_id=auth.uid();
 IF NOT FOUND THEN RAISE EXCEPTION 'Você não está nesta fila'; END IF;
 DELETE FROM public.inhouse_queue_entries WHERE id=e.id;
 IF e.side IS NOT NULL THEN PERFORM public.inhouse_promote_waiting(l.id,e.role,e.side); END IF;
END $$;

CREATE OR REPLACE FUNCTION public.inhouse_admin_action(p_lobby_id uuid,p_action text,p_player_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; e public.inhouse_queue_entries%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_permission('all') THEN RAISE EXCEPTION 'Somente ADM'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Partida inexistente'; END IF;
 IF p_action='CANCEL' THEN
 IF l.status IN('FINALIZADA','CANCELADA') THEN RAISE EXCEPTION 'Partida já encerrada'; END IF;
 UPDATE public.inhouse_lobbies SET status='CANCELADA' WHERE id=l.id;
 ELSIF p_action='REMOVE' THEN
 IF l.status<>'AGENDADA' THEN RAISE EXCEPTION 'Só é possível remover jogadores antes do draft'; END IF;
 SELECT * INTO e FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND player_id=p_player_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Jogador não encontrado'; END IF;
 DELETE FROM public.inhouse_queue_entries WHERE id=e.id;
 IF e.side IS NOT NULL THEN PERFORM public.inhouse_promote_waiting(l.id,e.role,e.side); END IF;
 ELSE RAISE EXCEPTION 'Ação inválida'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.inhouse_confirm(p_lobby_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_count int; v_total int;
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
   UPDATE public.inhouse_lobbies SET status='DRAFT',draft_step=0,draft_deadline=now()+interval '45 seconds' WHERE id=l.id;
   RETURN 'DRAFT';
 END IF;
 RETURN 'CONFIRMED';
END $$;

-- 0..9 são bans por função A/B. 10..19 são picks em ordem snake, a própria função é quem escolhe.
CREATE OR REPLACE FUNCTION public.inhouse_draft_actor(p_lobby_id uuid,p_turn integer)
RETURNS TABLE(player_id uuid,side text,action text,role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 WITH plan AS (
 SELECT p_turn AS turn,
 CASE WHEN p_turn<10 THEN (ARRAY['A','B','A','B','A','B','A','B','A','B'])[p_turn+1]
 ELSE (ARRAY['A','B','B','A','A','B','B','A','A','B'])[p_turn-9] END AS chosen_side,
 CASE WHEN p_turn<10 THEN (ARRAY['Top','Top','Jungle','Jungle','Mid','Mid','ADC','ADC','Support','Support'])[p_turn+1]
 ELSE (ARRAY['Top','Top','Jungle','Jungle','Mid','Mid','ADC','ADC','Support','Support'])[p_turn-9] END AS chosen_role)
 SELECT e.player_id,e.side,CASE WHEN p_turn<10 THEN 'BAN'::text ELSE 'PICK'::text END,e.role
 FROM public.inhouse_queue_entries e,plan p
 WHERE e.lobby_id=p_lobby_id AND e.status='CONFIRMED' AND e.side=p.chosen_side AND e.role=p.chosen_role
 LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.inhouse_draft_actor(uuid,integer) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.inhouse_draft_move(p_lobby_id uuid,p_champion text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; a record; champ text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'DRAFT' THEN RAISE EXCEPTION 'Draft indisponível'; END IF;
 IF now()>l.draft_deadline THEN RAISE EXCEPTION 'Tempo esgotado. Aguarde o avanço automático'; END IF;
 SELECT * INTO a FROM public.inhouse_draft_actor(l.id,l.draft_step);
 IF a.player_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Não é seu turno'; END IF;
 SELECT name INTO champ FROM public.inhouse_champions WHERE lower(name)=lower(trim(coalesce(p_champion,'')));
 IF champ IS NULL THEN RAISE EXCEPTION 'Campeão não cadastrado'; END IF;
 IF EXISTS(SELECT 1 FROM public.inhouse_draft_actions WHERE lobby_id=l.id AND champion=champ) THEN RAISE EXCEPTION 'Campeão já banido ou selecionado'; END IF;
 INSERT INTO public.inhouse_draft_actions(lobby_id,turn,player_id,side,action,champion)
 VALUES(l.id,l.draft_step,a.player_id,a.side,a.action,champ);
 IF l.draft_step=19 THEN
 UPDATE public.inhouse_lobbies SET draft_step=20,status='EM_JOGO',draft_deadline=NULL WHERE id=l.id;
 ELSE
 UPDATE public.inhouse_lobbies SET draft_step=l.draft_step+1,draft_deadline=now()+interval '45 seconds' WHERE id=l.id;
 END IF;
 RETURN l.draft_step+1;
END $$;

CREATE OR REPLACE FUNCTION public.inhouse_advance_draft(p_lobby_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; a record; champ text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Partida inexistente'; END IF;
 IF l.status<>'DRAFT' OR now()<l.draft_deadline THEN RETURN l.draft_step; END IF;
 SELECT * INTO a FROM public.inhouse_draft_actor(l.id,l.draft_step);
 IF a.player_id IS NULL THEN RAISE EXCEPTION 'Draft sem jogador para esta função'; END IF;
 IF l.draft_step>=10 THEN
 SELECT c.name INTO champ FROM public.inhouse_champions c
 WHERE NOT EXISTS(SELECT 1 FROM public.inhouse_draft_actions d WHERE d.lobby_id=l.id AND d.champion=c.name)
 ORDER BY c.name LIMIT 1;
 IF champ IS NULL THEN RAISE EXCEPTION 'Catálogo de campeões esgotado'; END IF;
 END IF;
 -- BAN vencido é passado; PICK vencido escolhe o primeiro campeão disponível.
 INSERT INTO public.inhouse_draft_actions(lobby_id,turn,player_id,side,action,champion,automatic)
 VALUES(l.id,l.draft_step,a.player_id,a.side,a.action,champ,true);
 IF l.draft_step=19 THEN
 UPDATE public.inhouse_lobbies SET draft_step=20,status='EM_JOGO',draft_deadline=NULL WHERE id=l.id;
 ELSE
 UPDATE public.inhouse_lobbies SET draft_step=l.draft_step+1,draft_deadline=now()+interval '45 seconds' WHERE id=l.id;
 END IF;
 RETURN l.draft_step+1;
END $$;

CREATE OR REPLACE FUNCTION public.inhouse_vote_result(p_lobby_id uuid,p_winner_side text,p_loser_games integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l public.inhouse_lobbies%ROWTYPE; v_count int;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Faça login'; END IF;
 SELECT * INTO l FROM public.inhouse_lobbies WHERE id=p_lobby_id FOR UPDATE;
 IF NOT FOUND OR l.status<>'EM_JOGO' THEN RAISE EXCEPTION 'Votação não disponível'; END IF;
 IF p_winner_side NOT IN('A','B') OR p_loser_games NOT IN(0,1) OR p_loser_games IS NULL THEN RAISE EXCEPTION 'Placar MD3 inválido'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.inhouse_queue_entries WHERE lobby_id=l.id AND player_id=auth.uid() AND status='CONFIRMED') THEN RAISE EXCEPTION 'Somente os dez participantes podem votar'; END IF;
 INSERT INTO public.inhouse_result_votes(lobby_id,voter_id,winner_side,loser_games)
 VALUES(l.id,auth.uid(),p_winner_side,p_loser_games)
 ON CONFLICT(lobby_id,voter_id) DO UPDATE SET winner_side=excluded.winner_side,loser_games=excluded.loser_games,created_at=now();
 SELECT count(*) INTO v_count FROM public.inhouse_result_votes WHERE lobby_id=l.id AND winner_side=p_winner_side AND loser_games=p_loser_games;
 IF v_count>=5 THEN
 UPDATE public.inhouse_lobbies SET status='FINALIZADA',winner_side=p_winner_side,
 score_a=CASE WHEN p_winner_side='A' THEN 2 ELSE p_loser_games END,
 score_b=CASE WHEN p_winner_side='B' THEN 2 ELSE p_loser_games END
 WHERE id=l.id;
 END IF;
 RETURN v_count;
END $$;

-- Somente as funções explicitamente listadas podem alterar fila, draft e votos.
REVOKE ALL ON FUNCTION public.inhouse_create_lobby(text,timestamptz,timestamptz,boolean),
 public.inhouse_admin_update(uuid,text,timestamptz,timestamptz,boolean),
 public.inhouse_admin_action(uuid,text,uuid),
 public.inhouse_join(uuid,text),public.inhouse_leave(uuid),public.inhouse_confirm(uuid),
 public.inhouse_draft_move(uuid,text),public.inhouse_advance_draft(uuid),
 public.inhouse_vote_result(uuid,text,integer)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.inhouse_create_lobby(text,timestamptz,timestamptz,boolean),
 public.inhouse_admin_update(uuid,text,timestamptz,timestamptz,boolean),
 public.inhouse_admin_action(uuid,text,uuid),
 public.inhouse_join(uuid,text),public.inhouse_leave(uuid),public.inhouse_confirm(uuid),
 public.inhouse_draft_move(uuid,text),public.inhouse_advance_draft(uuid),
 public.inhouse_vote_result(uuid,text,integer)
 TO authenticated;

-- Ranking individual acumula tanto partidas antigas 1x1 quanto as novas partidas 5x5 MD3.
CREATE OR REPLACE VIEW public.inhouse_ranking WITH (security_invoker=true) AS
WITH results AS (
 SELECT m.player_a AS player_id,m.match_format,m.score_a AS pf,m.score_b AS pa
 FROM public.inhouse_matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b
 UNION ALL
 SELECT m.player_b,m.match_format,m.score_b,m.score_a
 FROM public.inhouse_matches m WHERE m.status='FINALIZADA' AND m.score_a<>m.score_b
 UNION ALL
 SELECT q.player_id,'MD3'::text AS match_format,
 CASE WHEN q.side=l.winner_side THEN 2 ELSE least(l.score_a,l.score_b) END AS pf,
 CASE WHEN q.side=l.winner_side THEN least(l.score_a,l.score_b) ELSE 2 END AS pa
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
