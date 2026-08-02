// SPEC v3 §7.2 — il TTL del bucket `imports`, la metà che cancella davvero.
//
// Invocata dal cron una volta al giorno (migration 20260802160000). I candidati li decide
// `imports_stale_uploads` (SQL, service-only): file oltre il TTL non tenuti in vita da un job
// aperto. La cancellazione passa dalla Storage API — MAI da una DELETE su `storage.objects`:
// la riga sparirebbe, i byte su S3 no, e un TTL finto su export GDPR di terzi è peggio di
// nessun TTL.
//
// Il corpo accetta due override, pensati per il collaudo e utili solo al servizio (la
// funzione è dietro `cronAuth`, un client non arriva qui):
//   * `olderThanDays` — il TTL da applicare in questo giro (default 7);
//   * `prefix`        — restringe la cancellazione ai path che iniziano così, per provare
//                       il percorso end-to-end su una cartella sacrificabile senza toccare
//                       gli upload veri.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

/** Il limite della RPC: se i candidati sono esattamente questi, ce n'erano quasi certamente
 *  altri — si dichiara nell'esito invece di lasciare che "200 cancellati" sembri "finito". */
const RPC_LIMIT = 200

serve(async (req: Request) => {
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  let body: Record<string, unknown> = {}
  try { body = await req.json() } catch { /* corpo vuoto: i default vanno bene */ }

  const olderThanDays =
    typeof body.olderThanDays === 'number' && Number.isFinite(body.olderThanDays) && body.olderThanDays >= 0
      ? body.olderThanDays
      : 7
  const prefix = typeof body.prefix === 'string' && body.prefix.length > 0 ? body.prefix : null

  const admin = adminClient()

  const { data: stale, error: rpcError } = await admin.rpc('imports_stale_uploads', {
    p_older_than: `${olderThanDays} days`,
  })
  if (rpcError) {
    return jsonResponse({ error: 'stale_lookup_failed', detail: rpcError.message }, 500)
  }

  let paths = ((stale ?? []) as { name: string }[]).map((r) => r.name)
  const candidates = paths.length
  if (prefix) paths = paths.filter((p) => p.startsWith(prefix))

  if (paths.length === 0) {
    return jsonResponse({ deleted: 0, candidates, ttl_days: olderThanDays }, 200)
  }

  // `remove` risponde con gli oggetti rimossi: il conteggio dell'esito viene da lì, non dalla
  // lista che si è chiesta — la differenza fra richiesto e rimosso è la notizia, se c'è.
  const { data: removed, error: removeError } = await admin.storage.from('imports').remove(paths)
  if (removeError) {
    return jsonResponse(
      { error: 'remove_failed', detail: removeError.message, requested: paths.length },
      500,
    )
  }

  const esito: Record<string, unknown> = {
    deleted: removed?.length ?? 0,
    requested: paths.length,
    ttl_days: olderThanDays,
  }
  if (prefix) esito.prefix = prefix
  // Niente tagli muti: se la RPC ha riempito il proprio limite, il giro dopo continua da lì
  // e questo esito lo dice.
  if (candidates === RPC_LIMIT) esito.more_pending = true

  console.log('[imports-cleanup]', JSON.stringify(esito))
  return jsonResponse(esito, 200)
})
