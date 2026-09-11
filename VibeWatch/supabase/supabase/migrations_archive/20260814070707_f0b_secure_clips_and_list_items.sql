-- F0.b.1 — clips era world-writable: qualsiasi utente autenticato poteva
-- riscrivere l'intero catalogo (video_url, is_premium, ...). L'ingestion gira
-- con service key, quindi non e' toccata. Il path client di scrittura
-- (ClipsPrefetchService.storeClipsInSupabase) e' irraggiungibile — la guardia
-- getValidClipsCountInDB() >= 100 e' sempre vera con 3.309 clip attive — e in
-- ogni caso inghiotte gli errori di batch.
DROP POLICY IF EXISTS "Allow authenticated insert to clips" ON public.clips;
DROP POLICY IF EXISTS "Allow authenticated update to clips" ON public.clips;

-- TRUNCATE non e' filtrato da RLS: va tolto insieme alle scritture.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.clips FROM anon, authenticated;

-- F0.b.2 — list_items: la INSERT verificava solo il user_id della riga, non la
-- proprieta' della lista di destinazione. Via PostgREST diretto si potevano
-- inserire item nelle liste altrui (apply_mutations gia' lo impediva).
DROP POLICY IF EXISTS "Users can add items to own lists" ON public.list_items;
CREATE POLICY "Users can add items to own lists"
  ON public.list_items
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.lists l
      WHERE l.id = list_items.list_id
        AND l.user_id = (SELECT auth.uid())
    )
  );
