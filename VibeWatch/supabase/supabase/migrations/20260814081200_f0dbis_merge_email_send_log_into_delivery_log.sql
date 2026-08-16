-- F0.d-bis.3 — email_send_log confluisce in notification_delivery_log.
-- Sono due registri della stessa cosa (una consegna a un utente), entrambi
-- service-role-only con RLS attiva e zero policy. La differenza e' il canale.

ALTER TABLE public.notification_delivery_log
  ADD COLUMN IF NOT EXISTS channel text NOT NULL DEFAULT 'push';

ALTER TABLE public.notification_delivery_log
  ADD CONSTRAINT notification_delivery_log_channel_check
  CHECK (channel = ANY (ARRAY['push','email']));

-- `kind` ammetteva solo single/digest: i tipi email portano due valori in piu'.
ALTER TABLE public.notification_delivery_log
  DROP CONSTRAINT notification_delivery_log_kind_check;
ALTER TABLE public.notification_delivery_log
  ADD CONSTRAINT notification_delivery_log_kind_check
  CHECK (kind = ANY (ARRAY['single','digest','weekly_recap','fallback']));

-- Travaso: sent_at -> delivered_at, email_type -> kind, item_count -> notification_count.
INSERT INTO public.notification_delivery_log (user_id, delivered_at, kind, notification_count, channel)
SELECT e.user_id, e.sent_at, e.email_type, e.item_count, 'email'
  FROM public.email_send_log e;

DROP TABLE public.email_send_log;

CREATE INDEX IF NOT EXISTS notification_delivery_log_channel_delivered_idx
  ON public.notification_delivery_log (channel, delivered_at DESC);

COMMENT ON COLUMN public.notification_delivery_log.channel IS
  'push oppure email. Il budget giornaliero Resend si conta filtrando channel = ''email'' (_shared/resendBudget.ts).';

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM public.notification_delivery_log WHERE channel = 'email';
  IF n <> 2 THEN
    RAISE EXCEPTION 'attese 2 righe email dopo il travaso, trovate % — rollback', n;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
