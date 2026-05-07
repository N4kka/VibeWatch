-- BUG-01: Ensure updated_at column has DEFAULT on clip_comments
-- Column was defined in DDL but DEFAULT was absent from deployed schema, causing PGRST205
DO $$
BEGIN
  ALTER TABLE public.clip_comments
    ALTER COLUMN updated_at SET DEFAULT timezone('utc', now());
EXCEPTION
  WHEN undefined_column THEN
    ALTER TABLE public.clip_comments
      ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT timezone('utc', now());
END $$;

-- Backfill any rows that have NULL updated_at
UPDATE public.clip_comments
SET updated_at = now()
WHERE updated_at IS NULL;
