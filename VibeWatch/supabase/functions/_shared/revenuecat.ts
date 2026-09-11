// Lo stato Pro, chiesto a RevenueCat — l'unica fonte autorevole che abbiamo.
//
// **Perché non basta passare l'uid.** L'app_user_id di RevenueCat è
// case-sensitive; un uuid Postgres no. iOS chiama `Purchases.logIn(userId)` con
// l'id che si porta dietro da Foundation, e `UUID.uuidString` stampa in
// MAIUSCOLO (`AuthService.syncRevenueCatUser`): nei webhook infatti gli
// app_user_id arrivano come `9B339294-6F14-49A6-B977-693213AE89FB`. Ogni edge
// function, invece, legge lo stesso utente da Postgres o dal JWT, dove l'uuid è
// minuscolo. Per RevenueCat sono due account diversi, e — questa è la parte che
// fa danno — la GET su un id sconosciuto **non** risponde 404: risponde 200 con
// un subscriber nuovo e vuoto. L'entitlement risulta inattivo, chi ha pagato
// viene servito come Free, e la risposta sembra definitiva.
//
// È così che `reconcile-pro-status` ha demosso ogni abbonato la notte del
// 2026-08-15 (`user_entitlements`: 74 righe, zero `is_pro = true`) e che
// `cerebras-proxy` dava 8 richieste al giorno a un account Pro.
//
// Quindi si prova ogni grafia dell'id, la maiuscola per prima perché è quella
// che l'app registra: basta che una risponda "attivo". Una lettura andata storta
// non vale come "non è Pro" — torna `null`, e sta al chiamante decidere (nessuno
// deve perdere il Pro per un errore di rete).

/** `true` Pro · `false` non Pro (definitivo) · `null` indeterminato: non decidere. */
export type ProLookup = boolean | null

/** Le grafie sotto cui questo utente può essere registrato in RevenueCat. */
export function appUserIdVariants(userId: string): string[] {
  const upper = userId.toUpperCase()
  const lower = userId.toLowerCase()
  return upper === lower ? [userId] : [upper, lower]
}

export function isEntitlementActive(
  entitlement: { expires_date?: string | null } | undefined,
): boolean {
  if (!entitlement) return false
  // expires_date null => entitlement a vita (lifetime). Altrimenti deve essere nel futuro.
  if (entitlement.expires_date == null) return true
  return new Date(entitlement.expires_date).getTime() > Date.now()
}

export async function fetchIsProFromRevenueCat(
  userId: string,
  apiKey: string,
  entitlementId: string,
): Promise<ProLookup> {
  if (!apiKey) {
    console.warn('REVENUECAT_API_KEY non configurata; stato Pro indeterminato')
    return null
  }

  let indeterminate = false

  for (const appUserId of appUserIdVariants(userId)) {
    try {
      const resp = await fetch(
        `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`,
        { headers: { Authorization: `Bearer ${apiKey}` } },
      )
      if (!resp.ok) {
        console.warn(`RevenueCat lookup fallita (${resp.status}) per la grafia ${appUserId.slice(0, 8)}…`)
        indeterminate = true
        continue
      }
      const json = await resp.json()
      if (isEntitlementActive(json?.subscriber?.entitlements?.[entitlementId])) return true
    } catch (error) {
      console.warn('Errore lookup RevenueCat:', error)
      indeterminate = true
    }
  }

  // Nessuna grafia attiva. È un "no" solo se le ho potute chiedere tutte.
  return indeterminate ? null : false
}
