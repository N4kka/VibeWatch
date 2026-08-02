// Fase 4 dell'import TV Time (SPEC v3 §7.2): da `import_staging` a `watch_events`.
//
// Le regole stanno in `mutations.ts`, che è puro e testato. Qui c'è l'I/O e le tre cose che
// rendono questa fase diversa dalle precedenti:
//
//   * **`apply_mutations` gira come il chiamante, non come admin.** La funzione è `security
//     definer` ma si àncora ad `auth.uid()`: chiamata con la chiave di servizio solleva
//     `unauthenticated`. È anche giusto così — è l'utente che sta importando nel proprio account.
//   * **L'idempotenza non è del checkpoint ma della `dedup_key`.** Rigiocare lo stesso lotto non
//     duplica niente (criterio 2 di §13), quindi riprendere dal punto sbagliato costa lavoro, mai
//     dati doppi.
//   * **Un evento che non si può scrivere non si scrive approssimato.** Torna con la sua ragione
//     in `import_staging.error` e finisce nel report di §7.4: un import che dice "fatto" avendo
//     perso 200 episodi è peggio di uno che dichiara il problema.

import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { adminClient, jsonResponse } from '../_shared/proxy.ts'
import { isServiceCaller } from '../_shared/cronAuth.ts'
import {
  buildBatch,
  buildFavoriteBatch,
  buildRatingBatch,
  buildStatusBatch,
  type EpisodeMapEntry,
  type StagingRow,
} from './mutations.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

/**
 * Client che parla con il JWT del chiamante.
 *
 * Serve a due cose diverse e non intercambiabili: leggere il job facendo decidere la policy
 * invece di un `if` (è così che è nato l'IDOR di `import-parse`, riprodotto fra due utenti prima
 * di chiuderlo), e chiamare `apply_mutations`, che senza `auth.uid()` non parte.
 */
function callerClient(req: Request) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  })
}

/**
 * Righe lette per invocazione. Il tetto vero non è la memoria ma lo `statement_timeout = 8s` del
 * ruolo `authenticated`: `apply_mutations` cicla per elemento e ogni insert fa scattare il trigger
 * di ricalcolo, quindi il lotto va tenuto piccolo e le invocazioni tante.
 */
const ROWS_PER_INVOCATION = 500
/** Mutazioni per chiamata a `apply_mutations`. */
const MUTATIONS_PER_CALL = 100

serve(async (req: Request) => {
  if (req.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405)

  let jobId: string
  try {
    jobId = (await req.json()).job_id
    if (typeof jobId !== 'string' || jobId.length === 0) throw new Error('job_id')
  } catch {
    return jsonResponse({ error: 'job_id_required' }, 400)
  }

  const admin = adminClient()
  // Utente → RLS decide (chiusura dell'IDOR); driver del cron (§7.2, app chiusa) → service
  // key, che nessun client possiede. La differenza ritorna più sotto, dove si scrive.
  const daServizio = isServiceCaller(req)
  const caller = callerClient(req)
  const lookup = daServizio ? admin : caller

  const { data: job, error: jobError } = await lookup
    .from('import_jobs')
    .select('id, user_id, phase, status, totals')
    .eq('id', jobId)
    .maybeSingle()

  if (jobError) return jsonResponse({ error: 'job_lookup_failed', detail: jobError.message }, 401)
  if (!job) return jsonResponse({ error: 'job_not_found' }, 404)
  if (job.phase !== 'writing') return jsonResponse({ error: 'wrong_phase', phase: job.phase }, 409)

  try {
    const { data: pending, error: readError } = await admin
      .from('import_staging')
      .select('row_index, raw, resolved, status')
      .eq('job_id', jobId)
      .eq('status', 'resolved')
      .eq('raw->>row_kind', 'event')
      .order('row_index', { ascending: true })
      .limit(ROWS_PER_INVOCATION)

    if (readError) throw new Error(`lettura staging fallita: ${readError.message}`)

    if (!pending || pending.length === 0) {
      // Eventi finiti: prima gli stati per-serie (§7.1), che viaggiano sulle stesse mutazioni.
      const esitoStati = await scriviStati(admin, caller, daServizio, jobId, job.user_id,
        job.totals as Record<string, unknown> ?? {})
      if (esitoStati) return esitoStati

      // Poi i voti (§7.5), stessa strada; solo quando anche loro sono finiti si avanza.
      const esitoVoti = await scriviVoti(admin, caller, daServizio, jobId, job.user_id,
        job.totals as Record<string, unknown> ?? {})
      if (esitoVoti) return esitoVoti

      // Infine i favorites (§7.1): riempiono solo gli slot liberi, in ordine di preferenza.
      const esitoFavorites = await scriviFavorites(admin, caller, daServizio, jobId,
        job.user_id, job.totals as Record<string, unknown> ?? {})
      if (esitoFavorites) return esitoFavorites

      const { error } = await admin.from('import_jobs')
        .update({ phase: 'recomputing', checkpoint: {} }).eq('id', jobId)
      if (error) throw new Error(`avanzamento non salvato: ${error.message}`)

      return jsonResponse({ done: true, phase: 'recomputing', written: 0 }, 200)
    }

    const { mutations, written, skipped } = buildBatch(pending as StagingRow[], job.user_id)

    // Quante di queste ci sono già. Senza questo conteggio `totals.written` direbbe quante
    // mutazioni sono state *costruite*, non quante righe sono nate: rigiocando lo stesso lotto
    // il report dichiarerebbe il doppio degli episodi importati. Misurato nel collaudo — 558
    // eventi in tabella e 1116 dichiarati — ed è il genere di bugia che §7.4 esiste per evitare.
    const chiavi = mutations.map((m) => m.record.dedup_key as string)
    const giaPresenti = await countExisting(admin, job.user_id, chiavi)

    // `apply_mutations` non torna un esito per elemento: quello che rifiuta lo scrive in
    // `sync_rejected_mutations` e prosegue. Si conta prima e si confronta dopo, altrimenti una
    // perdita parziale passerebbe per un successo.
    const rifiutiPrima = await countRejected(admin, job.user_id)

    for (let i = 0; i < mutations.length; i += MUTATIONS_PER_CALL) {
      const lotto = mutations.slice(i, i + MUTATIONS_PER_CALL)
      // `apply_mutations` si àncora ad `auth.uid()`, e col service key non c'è: ad app chiusa
      // (driver del cron) si passa da `import_apply_mutations`, che imposta l'identità del
      // PROPRIETARIO del job — preso dalla riga, mai dalla richiesta — e delega. Solo
      // `service_role` può eseguirla: per un utente resta l'unica strada di sempre, il suo JWT.
      const { error } = daServizio
        ? await admin.rpc('import_apply_mutations', { p_user: job.user_id, batch: lotto })
        : await caller.rpc('apply_mutations', { batch: lotto })
      if (error) throw new Error(`apply_mutations ha rifiutato il lotto a ${i}: ${error.message}`)
    }

    const rifiutiDopo = await countRejected(admin, job.user_id)
    const nuoviRifiuti = rifiutiDopo - rifiutiPrima
    if (nuoviRifiuti > 0) {
      // Fallisce rumorosamente: un rifiuto qui vuol dire eventi persi, ed è esattamente il tipo
      // di perdita che questa pipeline esiste per non fare in silenzio.
      throw new Error(
        `${nuoviRifiuti} mutazioni rifiutate da apply_mutations: guardare sync_rejected_mutations`,
      )
    }

    if (written.length > 0) {
      const { error } = await admin.from('import_staging')
        .update({ status: 'written', error: null })
        .eq('job_id', jobId)
        .in('row_index', written)
      if (error) throw new Error(`marcatura righe scritte fallita: ${error.message}`)
    }

    // I saltati si marcano uno per uno perché ognuno porta la propria ragione: è il materiale
    // dell'elenco dei non riconosciuti che §7.4 rende obbligatorio.
    for (const { row_index, reason } of skipped) {
      const { error } = await admin.from('import_staging')
        .update({ status: 'skipped', error: `scrittura: ${reason}` })
        .eq('job_id', jobId).eq('row_index', row_index)
      if (error) throw new Error(`marcatura riga ${row_index} fallita: ${error.message}`)
    }

    const totaliPrecedenti = (job.totals as Record<string, number>) ?? {}
    const nuovi = written.length - giaPresenti
    const totals = {
      ...(job.totals as Record<string, unknown> ?? {}),
      written: (totaliPrecedenti.written ?? 0) + nuovi,
      already_present: (totaliPrecedenti.already_present ?? 0) + giaPresenti,
      not_written: (totaliPrecedenti.not_written ?? 0) + skipped.length,
    }

    const { error: updateError } = await admin.from('import_jobs')
      .update({ totals }).eq('id', jobId)
    if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

    return jsonResponse({
      done: false,
      phase: 'writing',
      written: nuovi,
      already_present: giaPresenti,
      skipped: skipped.length,
      totals,
    }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await admin.from('import_jobs')
      .update({ status: 'failed', error: message.slice(0, 500) }).eq('id', jobId)
    return jsonResponse({ error: 'write_failed', detail: message }, 500)
  }
})

/**
 * Quante mutazioni di questo utente sono già finite nello scarto.
 *
 * Si somma `occurrences`, **non** si contano le righe: `sync_rejected_mutations` è aggregata per
 * (utente, tabella, ragione, giorno), quindi cento rifiuti dello stesso tipo nello stesso giorno
 * lasciano il numero di righe identico e incrementano un contatore. Contare le righe avrebbe
 * detto "nessun rifiuto nuovo" proprio nel caso peggiore — un intero lotto perso.
 */
async function countRejected(
  admin: ReturnType<typeof adminClient>,
  userId: string,
): Promise<number> {
  const { data, error } = await admin
    .from('sync_rejected_mutations')
    .select('occurrences')
    .eq('user_id', userId)
  if (error) throw new Error(`conteggio dei rifiuti fallito: ${error.message}`)
  return (data ?? []).reduce((sum, r) => sum + (r.occurrences ?? 0), 0)
}

/**
 * Quante delle `dedup_key` di questo lotto sono già in `watch_events`.
 *
 * Si chiede a blocchi e non tutte insieme perché `in.(...)` finisce nella query string: 500
 * chiavi da ~25 caratteri fanno un URL da 12 KB, che è il genere di limite che si scopre quando
 * qualcuno importa più di quanto si sia provato.
 */
async function countExisting(
  admin: ReturnType<typeof adminClient>,
  userId: string,
  dedupKeys: string[],
): Promise<number> {
  const BLOCCO = 100
  let presenti = 0

  for (let i = 0; i < dedupKeys.length; i += BLOCCO) {
    const { data, error } = await admin
      .from('watch_events')
      .select('dedup_key')
      .eq('user_id', userId)
      .is('deleted_at', null)
      .in('dedup_key', dedupKeys.slice(i, i + BLOCCO))
    if (error) throw new Error(`conteggio dei già presenti fallito: ${error.message}`)
    presenti += data?.length ?? 0
  }

  return presenti
}

/**
 * La coda della fase 4: le righe `row_kind = 'status'` (§7.1) diventano upsert di
 * `tv_show_state` — è la strada già collaudata del ramo `tv_show_state` di `apply_mutations`
 * (upsert su (user_id, tmdb_show_id) + ricalcolo), quindi idempotente senza dedup_key.
 *
 * Risponde `null` quando non c'è più niente da fare, e il chiamante prosegue con i voti;
 * altrimenti una Response `done: false` e il giro dopo riprende da qui.
 */
async function scriviStati(
  admin: ReturnType<typeof adminClient>,
  caller: ReturnType<typeof callerClient>,
  daServizio: boolean,
  jobId: string,
  userId: string,
  totaliCorrenti: Record<string, unknown>,
): Promise<Response | null> {
  const { data: pending, error: readError } = await admin
    .from('import_staging')
    .select('row_index, raw, resolved, status')
    .eq('job_id', jobId)
    .eq('status', 'resolved')
    .eq('raw->>row_kind', 'status')
    .order('row_index', { ascending: true })
    .limit(ROWS_PER_INVOCATION)

  if (readError) throw new Error(`lettura stati fallita: ${readError.message}`)
  if (!pending || pending.length === 0) return null

  // Le serie che una riga di stato ce l'hanno già: servono alla regola "un `active` non
  // sovrascrive" di `buildStatusMutation`. Si chiede a blocchi per lo stesso limite di URL di
  // `countExisting`.
  const attiviIds = [
    ...new Set(
      (pending as StagingRow[])
        .filter((r) => (r.raw as Record<string, unknown>)?.user_status === 'active')
        .map((r) => Number((r.resolved as Record<string, unknown>)?.tmdb_show_id))
        .filter((n) => Number.isFinite(n) && n > 0),
    ),
  ]
  const esistenti = new Set<number>()
  for (let i = 0; i < attiviIds.length; i += 100) {
    const { data, error } = await admin
      .from('tv_show_state')
      .select('tmdb_show_id')
      .eq('user_id', userId)
      .in('tmdb_show_id', attiviIds.slice(i, i + 100))
    if (error) throw new Error(`lettura stati esistenti fallita: ${error.message}`)
    for (const r of data ?? []) esistenti.add(r.tmdb_show_id as number)
  }

  const { mutations, written, skipped } = buildStatusBatch(pending as StagingRow[], userId, esistenti)

  // Stessa sorveglianza degli eventi: `apply_mutations` non torna esiti per elemento, quindi i
  // rifiuti si contano prima e dopo — uno stato perso in silenzio è una serie che sparisce
  // dalla watchlist senza che nessuno lo dichiari.
  const rifiutiPrima = await countRejected(admin, userId)

  for (let i = 0; i < mutations.length; i += MUTATIONS_PER_CALL) {
    const lotto = mutations.slice(i, i + MUTATIONS_PER_CALL)
    const { error } = daServizio
      ? await admin.rpc('import_apply_mutations', { p_user: userId, batch: lotto })
      : await caller.rpc('apply_mutations', { batch: lotto })
    if (error) throw new Error(`apply_mutations ha rifiutato gli stati a ${i}: ${error.message}`)
  }

  const nuoviRifiuti = (await countRejected(admin, userId)) - rifiutiPrima
  if (nuoviRifiuti > 0) {
    throw new Error(
      `${nuoviRifiuti} stati rifiutati da apply_mutations: guardare sync_rejected_mutations`,
    )
  }

  if (written.length > 0) {
    const { error } = await admin.from('import_staging')
      .update({ status: 'written', error: null })
      .eq('job_id', jobId)
      .in('row_index', written)
    if (error) throw new Error(`marcatura stati scritti fallita: ${error.message}`)
  }

  for (const { row_index, reason } of skipped) {
    const { error } = await admin.from('import_staging')
      .update({ status: 'skipped', error: `stati: ${reason}` })
      .eq('job_id', jobId).eq('row_index', row_index)
    if (error) throw new Error(`marcatura stato ${row_index} fallita: ${error.message}`)
  }

  const prima = totaliCorrenti as Record<string, number>
  const giaInApp = skipped.filter((s) => s.reason === 'stato_gia_in_app').length
  const totals = {
    ...totaliCorrenti,
    statuses_applied: (prima.statuses_applied ?? 0) + written.length,
    statuses_kept_in_app: (prima.statuses_kept_in_app ?? 0) + giaInApp,
    statuses_not_written: (prima.statuses_not_written ?? 0) + (skipped.length - giaInApp),
  }

  const { error: updateError } = await admin.from('import_jobs')
    .update({ totals }).eq('id', jobId)
  if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

  return jsonResponse({
    done: false,
    phase: 'writing',
    stati: true,
    applicati: written.length,
    lasciati_in_app: giaInApp,
    skipped: skipped.length - giaInApp,
    totals,
  }, 200)
}

/**
 * La coda dei voti (§7.5): le righe `row_kind = 'rating'` diventano upsert di `user_ratings`
 * via `apply_mutations` (ramo del blocco 9: update-or-insert sulla chiave naturale, quindi
 * idempotente di suo).
 *
 * I voti NON passano dalla fase 3 (il commento in `import-resolve` lo dichiara): si agganciano
 * qui per `tvdb_episode_id` alla mappa globale, che gli eventi hanno già riempito — un voto
 * sta quasi sempre su un episodio visto, quindi zero chiamate TMDB. Ciò che la mappa non sa
 * è `non_risolto`, dichiarato nel report come per gli episodi.
 *
 * Risponde `null` quando non c'è più niente da fare; altrimenti `done: false` e il giro dopo
 * riprende da qui (le righe processate escono da `pending`, il progresso è nello staging).
 */
async function scriviVoti(
  admin: ReturnType<typeof adminClient>,
  caller: ReturnType<typeof callerClient>,
  daServizio: boolean,
  jobId: string,
  userId: string,
  totaliCorrenti: Record<string, unknown>,
): Promise<Response | null> {
  const { data: pending, error: readError } = await admin
    .from('import_staging')
    .select('row_index, raw, resolved, status')
    .eq('job_id', jobId)
    .eq('status', 'pending')
    .eq('raw->>row_kind', 'rating')
    .order('row_index', { ascending: true })
    .limit(ROWS_PER_INVOCATION)

  if (readError) throw new Error(`lettura voti fallita: ${readError.message}`)
  if (!pending || pending.length === 0) return null

  // La mappa globale per gli episodi votati, a blocchi (stesso limite di URL di countExisting).
  const episodeIds = [
    ...new Set(
      (pending as StagingRow[])
        .filter((r) => (r.raw as Record<string, unknown>)?.kind === 'star')
        .map((r) => Number((r.raw as Record<string, unknown>).tvdb_episode_id))
        .filter((n) => Number.isFinite(n) && n > 0),
    ),
  ]
  const mappa = new Map<number, EpisodeMapEntry>()
  for (let i = 0; i < episodeIds.length; i += 500) {
    const { data, error } = await admin
      .from('tvdb_tmdb_map')
      .select('tvdb_id, tmdb_show_id, season_number, episode_number, resolution')
      .eq('entity_type', 'episode')
      .in('tvdb_id', episodeIds.slice(i, i + 500))
    if (error) throw new Error(`lettura mappa per i voti fallita: ${error.message}`)
    for (const row of data ?? []) {
      mappa.set(row.tvdb_id as number, row as unknown as EpisodeMapEntry)
    }
  }

  // I voti già in app, LAPIDI COMPRESE: un voto cancellato in app dopo l'export non deve
  // risorgere al re-import — è la regola "un voto già presente non si sovrascrive" di
  // buildRatingMutation, e le lapidi ne fanno parte.
  const showIds = [
    ...new Set(
      [...mappa.values()]
        .filter((v) => v.resolution === 'found' && v.tmdb_show_id !== null)
        .map((v) => v.tmdb_show_id as number),
    ),
  ]
  const esistenti = new Set<string>()
  for (let i = 0; i < showIds.length; i += 100) {
    const { data, error } = await admin
      .from('user_ratings')
      .select('tmdb_id, season_number, episode_number')
      .eq('user_id', userId)
      .eq('media_type', 'episode')
      .in('tmdb_id', showIds.slice(i, i + 100))
    if (error) throw new Error(`lettura voti esistenti fallita: ${error.message}`)
    for (const r of data ?? []) {
      esistenti.add(`${r.tmdb_id}:${r.season_number}:${r.episode_number}`)
    }
  }

  const { mutations, written, skipped } = buildRatingBatch(
    pending as StagingRow[], userId, mappa, esistenti)

  // Stessa sorveglianza di eventi e stati: i rifiuti si contano prima e dopo.
  const rifiutiPrima = await countRejected(admin, userId)

  for (let i = 0; i < mutations.length; i += MUTATIONS_PER_CALL) {
    const lotto = mutations.slice(i, i + MUTATIONS_PER_CALL)
    const { error } = daServizio
      ? await admin.rpc('import_apply_mutations', { p_user: userId, batch: lotto })
      : await caller.rpc('apply_mutations', { batch: lotto })
    if (error) throw new Error(`apply_mutations ha rifiutato i voti a ${i}: ${error.message}`)
  }

  const nuoviRifiuti = (await countRejected(admin, userId)) - rifiutiPrima
  if (nuoviRifiuti > 0) {
    throw new Error(
      `${nuoviRifiuti} voti rifiutati da apply_mutations: guardare sync_rejected_mutations`,
    )
  }

  if (written.length > 0) {
    const { error } = await admin.from('import_staging')
      .update({ status: 'written', error: null })
      .eq('job_id', jobId)
      .in('row_index', written)
    if (error) throw new Error(`marcatura voti scritti fallita: ${error.message}`)
  }

  for (const { row_index, reason } of skipped) {
    const { error } = await admin.from('import_staging')
      .update({ status: 'skipped', error: `voti: ${reason}` })
      .eq('job_id', jobId).eq('row_index', row_index)
    if (error) throw new Error(`marcatura voto ${row_index} fallita: ${error.message}`)
  }

  const prima = totaliCorrenti as Record<string, number>
  const giaInApp = skipped.filter((s) => s.reason === 'voto_gia_in_app').length
  const reactions = skipped.filter((s) => s.reason === 'reaction_conservata').length
  const totals = {
    ...totaliCorrenti,
    ratings_applied: (prima.ratings_applied ?? 0) + written.length,
    ratings_kept_in_app: (prima.ratings_kept_in_app ?? 0) + giaInApp,
    ratings_reactions_kept: (prima.ratings_reactions_kept ?? 0) + reactions,
    ratings_not_written:
      (prima.ratings_not_written ?? 0) + (skipped.length - giaInApp - reactions),
  }

  const { error: updateError } = await admin.from('import_jobs')
    .update({ totals }).eq('id', jobId)
  if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

  return jsonResponse({
    done: false,
    phase: 'writing',
    voti: true,
    applicati: written.length,
    gia_in_app: giaInApp,
    reactions_conservate: reactions,
    skipped: skipped.length - giaInApp - reactions,
    totals,
  }, 200)
}

/**
 * La coda dei favorites (§7.1): le righe `row_kind = 'favorite'` risolte riempiono gli slot
 * LIBERI di `user_favorites` (media_type tv), in ordine di `row_index` — che la fase 2 ha
 * fissato sull'ordine di preferenza di TV Time, i più vecchi prima. Deciso dall'utente il
 * 2026-08-02: mai sovrascrivere uno slot che ha una riga, viva o lapide — una lapide è uno
 * slot svuotato apposta in app, e riempirlo disfarebbe quella scelta (regola dei voti).
 *
 * Il ramo `user_favorites` di `apply_mutations` è un upsert lastWriteWins sulla PK: è la
 * lettura degli slot qui sotto a garantire che l'import non sovrascriva mai — per questo si
 * scrive SOLO su slot senza riga.
 */
async function scriviFavorites(
  admin: ReturnType<typeof adminClient>,
  caller: ReturnType<typeof callerClient>,
  daServizio: boolean,
  jobId: string,
  userId: string,
  totaliCorrenti: Record<string, unknown>,
): Promise<Response | null> {
  const { data: pending, error: readError } = await admin
    .from('import_staging')
    .select('row_index, raw, resolved, status')
    .eq('job_id', jobId)
    .eq('status', 'resolved')
    .eq('raw->>row_kind', 'favorite')
    .order('row_index', { ascending: true })
    .limit(ROWS_PER_INVOCATION)

  if (readError) throw new Error(`lettura favorites fallita: ${readError.message}`)
  if (!pending || pending.length === 0) return null

  // Gli slot TV di oggi, lapidi COMPRESE: uno slot con una riga non e' libero.
  const { data: slotRows, error: slotsError } = await admin
    .from('user_favorites')
    .select('slot, tmdb_id, deleted_at')
    .eq('user_id', userId)
    .eq('media_type', 'tv')
  if (slotsError) throw new Error(`lettura slot favorites fallita: ${slotsError.message}`)

  const occupati = new Set((slotRows ?? []).map((r) => r.slot as number))
  const slotLiberi = [1, 2, 3, 4].filter((s) => !occupati.has(s))
  const giaFavoriti = new Set(
    (slotRows ?? [])
      .filter((r) => r.deleted_at === null)
      .map((r) => r.tmdb_id as number),
  )

  const { mutations, written, skipped } = buildFavoriteBatch(
    pending as StagingRow[], userId, slotLiberi, giaFavoriti)

  // Stessa sorveglianza delle altre code: i rifiuti si contano prima e dopo.
  const rifiutiPrima = await countRejected(admin, userId)

  for (let i = 0; i < mutations.length; i += MUTATIONS_PER_CALL) {
    const lotto = mutations.slice(i, i + MUTATIONS_PER_CALL)
    const { error } = daServizio
      ? await admin.rpc('import_apply_mutations', { p_user: userId, batch: lotto })
      : await caller.rpc('apply_mutations', { batch: lotto })
    if (error) throw new Error(`apply_mutations ha rifiutato i favorites a ${i}: ${error.message}`)
  }

  const nuoviRifiuti = (await countRejected(admin, userId)) - rifiutiPrima
  if (nuoviRifiuti > 0) {
    throw new Error(
      `${nuoviRifiuti} favorites rifiutati da apply_mutations: guardare sync_rejected_mutations`,
    )
  }

  if (written.length > 0) {
    const { error } = await admin.from('import_staging')
      .update({ status: 'written', error: null })
      .eq('job_id', jobId)
      .in('row_index', written)
    if (error) throw new Error(`marcatura favorites scritti fallita: ${error.message}`)
  }

  for (const { row_index, reason } of skipped) {
    const { error } = await admin.from('import_staging')
      .update({ status: 'skipped', error: `favorites: ${reason}` })
      .eq('job_id', jobId).eq('row_index', row_index)
    if (error) throw new Error(`marcatura favorite ${row_index} fallita: ${error.message}`)
  }

  const prima = totaliCorrenti as Record<string, number>
  const slotPieni = skipped.filter((s) => s.reason === 'slot_pieni').length
  const giaInApp = skipped.filter((s) => s.reason === 'gia_favorito').length
  const totals = {
    ...totaliCorrenti,
    favorites_applied: (prima.favorites_applied ?? 0) + written.length,
    favorites_slots_full: (prima.favorites_slots_full ?? 0) + slotPieni,
    favorites_already_in_app: (prima.favorites_already_in_app ?? 0) + giaInApp,
  }

  const { error: updateError } = await admin.from('import_jobs')
    .update({ totals }).eq('id', jobId)
  if (updateError) throw new Error(`totali non salvati: ${updateError.message}`)

  return jsonResponse({
    done: false,
    phase: 'writing',
    favorites: true,
    applicati: written.length,
    slot_pieni: slotPieni,
    gia_in_app: giaInApp,
    totals,
  }, 200)
}
