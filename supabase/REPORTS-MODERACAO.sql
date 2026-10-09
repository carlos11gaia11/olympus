-- OLYMPUS: execute APOS schema.sql e ATUALIZACAO-SEGURA.sql.
-- Cria campos de denúncia e uma função transacional para decisões administrativas.
BEGIN;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS target_type text;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS target_id uuid;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS decision_reason text;
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS reputation_penalty integer NOT NULL DEFAULT 0;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='reports_target_type_check' AND conrelid='public.reports'::regclass) THEN
  ALTER TABLE public.reports ADD CONSTRAINT reports_target_type_check CHECK (target_type IN ('player','team')) NOT VALID; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='reports_penalty_check' AND conrelid='public.reports'::regclass) THEN
  ALTER TABLE public.reports ADD CONSTRAINT reports_penalty_check CHECK (reputation_penalty BETWEEN 0 AND 100) NOT VALID; END IF;
END $$;
-- Relatos antigos podem não ter alvo; novos relatos são validados pelo gatilho abaixo.
CREATE OR REPLACE FUNCTION public.validate_report_submission()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
 IF TG_OP = 'INSERT' THEN
  IF NEW.target_type NOT IN ('player','team') OR NEW.target_id IS NULL THEN
   RAISE EXCEPTION 'Escolha um jogador ou time';
  END IF;
  IF NEW.target_type='player' AND NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=NEW.target_id) THEN
   RAISE EXCEPTION 'Jogador não encontrado';
  END IF;
  IF NEW.target_type='team' AND NOT EXISTS(SELECT 1 FROM public.teams WHERE id=NEW.target_id) THEN
   RAISE EXCEPTION 'Time não encontrado';
  END IF;
  IF NEW.target_type='player' AND NEW.target_id=auth.uid() THEN
   RAISE EXCEPTION 'Você não pode denunciar seu próprio perfil';
  END IF;
  NEW.status='ABERTO'; NEW.reputation_penalty=0;NEW.reviewed_at=NULL;NEW.reviewed_by=NULL;NEW.decision_reason=NULL;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS validate_report_submission ON public.reports;
CREATE TRIGGER validate_report_submission BEFORE INSERT ON public.reports
FOR EACH ROW EXECUTE FUNCTION public.validate_report_submission();

-- Nem mesmo administradores alteram a decisão diretamente por REST;
-- apenas a RPC transacional pode finalizar uma denúncia.
DROP POLICY IF EXISTS reports_admin_update ON public.reports;
REVOKE UPDATE, DELETE ON public.reports FROM anon, authenticated;
GRANT SELECT, INSERT ON public.reports TO authenticated;
GRANT UPDATE ON public.profiles, public.team_stats TO authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;

CREATE TABLE IF NOT EXISTS public.report_penalty_log (
 report_id uuid PRIMARY KEY REFERENCES public.reports(id) ON DELETE RESTRICT,
 target_type text NOT NULL,
 target_id uuid NOT NULL,
 reputation_before integer NOT NULL,
 reputation_after integer NOT NULL,
 points_requested integer NOT NULL,
 reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.report_penalty_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.report_penalty_log FROM anon, authenticated;
GRANT SELECT ON public.report_penalty_log TO authenticated;
DROP POLICY IF EXISTS report_penalty_log_admin_read ON public.report_penalty_log;
CREATE POLICY report_penalty_log_admin_read ON public.report_penalty_log
 FOR SELECT TO authenticated USING (public.has_permission('all'));

CREATE OR REPLACE FUNCTION public.review_report(
 p_report_id uuid, p_decision text, p_penalty integer, p_reason text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.reports%ROWTYPE;before_points integer;after_points integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_permission('all') THEN RAISE EXCEPTION 'Acesso restrito a administradores'; END IF;
 IF p_decision NOT IN ('APROVADO','REJEITADO') THEN RAISE EXCEPTION 'Decisão inválida'; END IF;
 IF p_penalty IS NULL OR p_penalty < 0 OR p_penalty > 100 THEN RAISE EXCEPTION 'Punição deve estar entre 0 e 100'; END IF;
 IF length(trim(coalesce(p_reason,''))) < 3 OR length(p_reason)>500 THEN RAISE EXCEPTION 'Informe justificativa de 3 a 500 caracteres'; END IF;
 IF p_decision='REJEITADO' AND p_penalty<>0 THEN RAISE EXCEPTION 'Rejeição não aplica desconto'; END IF;
 SELECT * INTO r FROM public.reports WHERE id=p_report_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Report não encontrado'; END IF;
 IF r.status <> 'ABERTO' THEN RAISE EXCEPTION 'Report já analisado'; END IF;
 IF r.target_type NOT IN ('player','team') OR r.target_id IS NULL THEN RAISE EXCEPTION 'Report legado sem alvo: defina o alvo antes de analisar'; END IF;
 IF p_decision='APROVADO' AND p_penalty>0 THEN
  IF r.target_type='player' THEN
   SELECT reputation INTO before_points FROM public.profiles WHERE id=r.target_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Jogador não encontrado'; END IF;
   after_points=greatest(0,before_points-p_penalty);
   UPDATE public.profiles SET reputation=after_points WHERE id=r.target_id;
  ELSE
   -- Time pode existir ainda sem registro em team_stats.
   INSERT INTO public.team_stats(team_id,reputation) VALUES(r.target_id,0)
     ON CONFLICT(team_id) DO NOTHING;
   SELECT reputation INTO before_points FROM public.team_stats WHERE team_id=r.target_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Time não encontrado'; END IF;
   after_points=greatest(0,before_points-p_penalty);
   UPDATE public.team_stats SET reputation=after_points WHERE team_id=r.target_id;
  END IF;
  INSERT INTO public.report_penalty_log(report_id,target_type,target_id,reputation_before,reputation_after,points_requested,reviewed_by)
  VALUES(r.id,r.target_type,r.target_id,before_points,after_points,p_penalty,auth.uid());
 END IF;
 UPDATE public.reports SET status=p_decision, reviewed_by=auth.uid(), reviewed_at=now(),
 decision_reason=trim(p_reason),reputation_penalty=CASE WHEN p_decision='APROVADO' THEN p_penalty ELSE 0 END
 WHERE id=p_report_id;
END $$;
REVOKE ALL ON FUNCTION public.review_report(uuid,text,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_report(uuid,text,integer,text) TO authenticated;
COMMIT;
