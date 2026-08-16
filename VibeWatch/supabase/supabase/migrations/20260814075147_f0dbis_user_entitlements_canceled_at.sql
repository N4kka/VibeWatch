-- F0.d-bis.6 — la data di cancellazione va dove sta gia' lo stato
-- dell'abbonamento. profiles.subscription_canceled_at era l'unica colonna
-- `timestamp without time zone` dello schema: RevenueCat manda ISO 8601 con
-- offset, e Postgres lo troncava silenziosamente al fuso della sessione.
-- Qui e' timestamptz.
ALTER TABLE public.user_entitlements
  ADD COLUMN IF NOT EXISTS canceled_at timestamptz;

COMMENT ON COLUMN public.user_entitlements.canceled_at IS
  'Data di cancellazione dal webhook RevenueCat (evento CANCELLATION). Sostituisce profiles.subscription_canceled_at, che era timestamp senza fuso.';

-- Travaso di quanto c'e' (in pratica zero righe: la colonna non ha mai avuto
-- lettori, ma non si butta via un dato senza guardarlo).
UPDATE public.user_entitlements e
   SET canceled_at = p.subscription_canceled_at AT TIME ZONE 'UTC'
  FROM public.profiles p
 WHERE p.id = e.user_id
   AND p.subscription_canceled_at IS NOT NULL
   AND e.canceled_at IS NULL;
