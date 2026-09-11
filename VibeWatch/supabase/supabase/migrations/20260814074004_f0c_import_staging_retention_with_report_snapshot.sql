-- F0.c.3 — retention di import_staging (185 MB, 57% del database, 196.918 righe
-- per 9 job tutti chiusi da oltre 10 giorni).
--
-- CORREZIONE AL PIANO. Il piano diceva di salvare in `import_jobs.totals` gli
-- aggregati per job e poi cancellare. Ma `totals` e' gia' popolato su tutti e 9
-- i job e NON contiene il report: `import_report()` calcola quasi ogni suo campo
-- leggendo `import_staging` riga per riga — dal conteggio degli episodi agli
-- elenchi di serie e film non riconosciuti, che sono dati che l'utente puo'
-- ancora aprire. Cancellare lo staging avrebbe azzerato tutti e 9 i report.
--
-- Qui invece lo snapshot e' del report intero, e viene preso nella stessa
-- transazione della cancellazione. L'invariante e': report_snapshot NOT NULL
-- <=> staging cancellato.

ALTER TABLE public.import_jobs
  ADD COLUMN IF NOT EXISTS report_snapshot jsonb;

COMMENT ON COLUMN public.import_jobs.report_snapshot IS
  'Output congelato di import_report() preso appena prima di eliminare le righe di import_staging del job. NOT NULL significa che lo staging non c''e'' piu''.';

-- Il corpo storico diventa il calcolo "dal vivo".
ALTER FUNCTION public.import_report(uuid) RENAME TO import_report_live;

-- import_report mantiene firma, grant e semantica SECURITY INVOKER (la RLS di
-- import_jobs continua a limitare ogni utente ai propri job): restituisce lo
-- snapshot se c'e', altrimenti calcola.
CREATE OR REPLACE FUNCTION public.import_report(p_job_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select j.report_snapshot from public.import_jobs j
      where j.id = p_job_id and j.report_snapshot is not null),
    public.import_report_live(p_job_id)
  );
$function$;

REVOKE ALL ON FUNCTION public.import_report_live(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.import_report_live(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.import_report(uuid) TO authenticated, service_role;

-- Potatura: per ogni job chiuso e piu' vecchio della finestra, congela il report
-- e poi cancella le sue righe di staging. Un job per volta, cosi' un errore su
-- uno non porta con se' gli altri.
CREATE OR REPLACE FUNCTION public.imports_prune_staging(p_older_than interval DEFAULT '7 days')
 RETURNS TABLE(jobs_pruned integer, rows_deleted bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  j record;
  n_jobs integer := 0;
  n_rows bigint := 0;
  deleted bigint;
BEGIN
  FOR j IN
    SELECT id FROM public.import_jobs
     WHERE status = 'done'
       AND updated_at < now() - p_older_than
       AND report_snapshot IS NULL
       AND EXISTS (SELECT 1 FROM public.import_staging s WHERE s.job_id = public.import_jobs.id)
  LOOP
    -- Prima si congela, poi si cancella: se lo snapshot fallisce, le righe
    -- restano dove sono.
    UPDATE public.import_jobs
       SET report_snapshot = public.import_report_live(j.id)
     WHERE id = j.id;

    DELETE FROM public.import_staging WHERE job_id = j.id;
    GET DIAGNOSTICS deleted = ROW_COUNT;

    n_jobs := n_jobs + 1;
    n_rows := n_rows + deleted;
  END LOOP;

  RETURN QUERY SELECT n_jobs, n_rows;
END;
$function$;

REVOKE ALL ON FUNCTION public.imports_prune_staging(interval) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.imports_prune_staging(interval) TO service_role;
