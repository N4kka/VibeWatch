// Fase 4 dell'import TV Time (SPEC v3 §7.2), logica pura: da una riga di `import_staging` alla
// mutazione che `apply_mutations` sa applicare. Separata da `index.ts` perché quello chiama
// `serve()` appena importato e non è collaudabile.
//
// Tutto ciò che questo modulo decide è verificabile senza database, ed è dove stanno le tre
// scelte che possono corrompere l'import in silenzio: da dove viene la stagione, da dove viene
// la specialità, e cosa significa un runtime a zero.

/** Il record di staging, già annotato dalla fase `resolving`. */
export interface StagingRow {
  row_index: number
  raw: Record<string, unknown>
  resolved: Record<string, unknown> | null
  status: string
}

/** L'involucro che `apply_mutations(batch jsonb)` si aspetta. */
export interface Mutation {
  op: 'INSERT'
  table: 'watch_events' | 'tv_show_state' | 'user_ratings'
  record: Record<string, unknown>
}

export type SkipReason =
  | 'non_risolto'
  | 'numerazione_mancante'
  | 'show_mancante'
  | 'senza_dedup_key'
  | 'stato_non_valido'
  | 'stato_gia_in_app'
  | 'reaction_conservata'
  | 'voto_gia_in_app'
  | 'voto_fuori_scala'
  | 'senza_episodio'

export interface BuildOutcome {
  mutation: Mutation | null
  skip: SkipReason | null
}

/**
 * §1.3 `DECISO`. Gemella di `public.is_special_episode(integer)` e della funzione omonima in
 * `import-parse/parsing.ts`.
 *
 * **Va applicata alla stagione risolta da TMDB, non a quella dell'export.** Dopo la fase
 * `resolving` la stagione autorevole è quella di TMDB (§6), ed è quella che
 * `recompute_tv_show_state` filtra: scrivere in `watch_events.is_special` un valore derivato
 * dall'export significherebbe mettere in colonna un dato che contraddice la funzione che calcola
 * il progresso una riga più in là.
 */
export function isSpecialEpisode(seasonNumber: number | null): boolean {
  return (seasonNumber ?? 0) === 0
}

/**
 * I timestamp dell'export sono `YYYY-MM-DD HH:MM:SS` **in UTC**, senza fuso scritto.
 *
 * Verificato e non supposto: su 430 serie, l'epoch in microsecondi di `most_recent_ep_watched`
 * coincide con la stringa `created_at` dello stesso evento in 425 casi interpretandola come UTC,
 * e le 5 differenze non hanno forma di fuso — sono altri eventi sullo stesso episodio.
 *
 * Il fuso si scrive esplicito invece di lasciarlo dedurre a Postgres: `watch_events.watched_at` è
 * `timestamptz`, e una stringa senza fuso viene interpretata secondo il GUC `TimeZone` della
 * sessione. Oggi è UTC e verrebbe uguale; il giorno che cambiasse, 21.000 date si sposterebbero
 * tutte insieme senza che niente fallisca.
 */
export function toUtcIso(watchedAt: string): string | null {
  const trimmed = (watchedAt ?? '').trim()
  if (trimmed === '') return null
  if (/[zZ]$|[+-]\d{2}:?\d{2}$/.test(trimmed)) return trimmed.replace(' ', 'T')
  if (!/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}/.test(trimmed)) return null
  return `${trimmed.replace(' ', 'T')}Z`
}

/**
 * Un `runtime` a 0 nell'export vuol dire "non lo so", non "dura zero".
 *
 * Sono 309 eventi sull'export reale, e sono le stesse righe orfane che hanno perso anche la
 * numerazione. Scriverli come 0 li renderebbe indistinguibili da un episodio davvero istantaneo e
 * andrebbe a sporcare il totale di tempo di visione, che §13.7 vuole calcolato su runtime reali.
 * A `null` il totale può invece attingere a `tmdb_episodes.runtime_minutes`, che è la fonte buona.
 */
export function runtimeOrNull(runtimeSeconds: unknown): number | null {
  const n = Number(runtimeSeconds)
  return Number.isFinite(n) && n > 0 ? n : null
}

/**
 * `null` e stringa vuota NON sono zero.
 *
 * `Number(null)` è `0` e `Number('')` è `0`, entrambi interi: senza questa guardia una stagione
 * o un episodio mancanti diventavano **episodio 0** e venivano scritti come se fossero un
 * episodio vero. È la stessa trappola di `episode_number = 0` chiusa nel parser (§6), che si
 * ripresenta identica un passaggio più in là — e qui il danno sarebbe peggiore, perché §1.3
 * leggerebbe quello zero come "speciale". L'ha trovata il test dei casi non scrivibili.
 */
function asInt(value: unknown): number | null {
  if (value === null || value === undefined) return null
  if (typeof value === 'string' && value.trim() === '') return null
  const n = Number(value)
  return Number.isInteger(n) ? n : null
}

/**
 * Da riga di staging a mutazione, o al motivo per cui non se ne fa una.
 *
 * Non esiste il caso "scrivo qualcosa di approssimato": il CHECK `watch_events_shape` pretende
 * stagione ed episodio non nulli per un evento `tv`, e inventarli è esattamente ciò che §7.4
 * chiede di non fare. Una riga che non si può scrivere torna con la sua ragione e finisce nel
 * report.
 */
export function buildEventMutation(row: StagingRow, userId: string): BuildOutcome {
  const raw = row.raw ?? {}
  const resolved = row.resolved

  if (!resolved) return { mutation: null, skip: 'non_risolto' }

  const showId = asInt(resolved.tmdb_show_id)
  if (showId === null) return { mutation: null, skip: 'show_mancante' }

  // I numeri vengono da TMDB, mai da quelli dell'export (§6). L'export li ha sbagliati per
  // costruzione su 31 serie, e su 195 eventi non li ha affatto.
  const season = asInt(resolved.season_number)
  const episode = asInt(resolved.episode_number)
  if (season === null || episode === null) {
    return { mutation: null, skip: 'numerazione_mancante' }
  }

  const watchedAt = toUtcIso(String(raw.watched_at ?? ''))
  if (watchedAt === null) return { mutation: null, skip: 'numerazione_mancante' }

  // Senza `dedup_key` un reimport duplicherebbe l'evento: `apply_mutations` deduplica su quella,
  // e criterio 2 di §13 dice che reimportare lo stesso ZIP non deve duplicare niente.
  const dedupKey = typeof raw.dedup_key === 'string' && raw.dedup_key !== ''
    ? raw.dedup_key
    : null
  if (dedupKey === null) return { mutation: null, skip: 'senza_dedup_key' }

  return {
    skip: null,
    mutation: {
      op: 'INSERT',
      table: 'watch_events',
      record: {
        // **Obbligatorio.** `apply_mutations` confronta `rec->>'user_id'` con `auth.uid()` e, se
        // manca o non combacia, scrive `user_id_mismatch` in `sync_rejected_mutations` e tira
        // dritto: nessun errore visibile, e l'import perde l'evento in silenzio.
        user_id: userId,
        media_type: 'tv',
        tmdb_show_id: showId,
        season_number: season,
        episode_number: episode,
        watched_at: watchedAt,
        watched_at_precision: raw.watched_at_precision ?? 'exact',
        runtime_seconds: runtimeOrNull(raw.runtime_seconds),
        is_special: isSpecialEpisode(season),
        rewatch_index: asInt(raw.rewatch_index) ?? 0,
        source: 'import_tvtime',
        // Tutto ciò che non ha una colonna ma non va perso: gli id di origine servono a rifare
        // il lavoro, e il flag di TV Time è il criterio con cui contava lui (vedi
        // `.planning/spec-v3-oracle.md`).
        external_ref: {
          tvdb_episode_id: raw.tvdb_episode_id ?? null,
          tvdb_series_id: raw.tvdb_series_id ?? null,
          tvtime_is_special: raw.tvtime_is_special_raw ?? null,
          tvtime_bulk_type: raw.bulk_type ?? null,
        },
        dedup_key: dedupKey,
      },
    },
  }
}

/** Gli unici valori che la CHECK di `tv_show_state.user_status` accetta e che l'import emette. */
const STATI_AMMESSI = new Set(['active', 'for_later', 'archived'])

/**
 * Da riga di staging `row_kind = 'status'` (§7.1) alla mutazione `tv_show_state`.
 *
 * Il ramo di `apply_mutations` fa upsert su (user_id, tmdb_show_id) e poi ricalcola, quindi la
 * mutazione è idempotente di suo — niente dedup_key. Le due regole in più:
 *
 *   - **`for_later`/`archived` sovrascrivono uno stato già presente in app**: è lo stato che
 *     l'utente aveva scelto su TV Time, importarlo è esattamente il lavoro richiesto.
 *   - **`active` invece NO** (`esistenti` sono le serie che una riga ce l'hanno già): `active`
 *     qui significa solo "seguita mai iniziata, falla esistere". Se la riga esiste, l'utente può
 *     averle già dato uno stato in app, e riportarla ad `active` sarebbe l'import che disfa una
 *     scelta fatta dopo l'export.
 */
export function buildStatusMutation(
  row: StagingRow,
  userId: string,
  esistenti: Set<number>,
): BuildOutcome {
  const raw = row.raw ?? {}
  const resolved = row.resolved

  if (!resolved) return { mutation: null, skip: 'non_risolto' }

  const showId = asInt(resolved.tmdb_show_id)
  if (showId === null) return { mutation: null, skip: 'show_mancante' }

  const stato = typeof raw.user_status === 'string' ? raw.user_status : ''
  if (!STATI_AMMESSI.has(stato)) return { mutation: null, skip: 'stato_non_valido' }

  if (stato === 'active' && esistenti.has(showId)) {
    return { mutation: null, skip: 'stato_gia_in_app' }
  }

  return {
    skip: null,
    mutation: {
      op: 'INSERT',
      table: 'tv_show_state',
      record: {
        // Stesso obbligo degli eventi: senza `user_id` combaciante, `apply_mutations` scarta in
        // silenzio verso `sync_rejected_mutations`.
        user_id: userId,
        tmdb_show_id: showId,
        user_status: stato,
      },
    },
  }
}

export interface BuiltBatch {
  mutations: Mutation[]
  written: number[]
  skipped: { row_index: number; reason: SkipReason }[]
}

/** La riga di `tvdb_tmdb_map` per un episodio, ridotta a ciò che serve ai voti. */
export interface EpisodeMapEntry {
  resolution: string
  tmdb_show_id: number | null
  season_number: number | null
  episode_number: number | null
}

/**
 * §7.5: da riga di staging `row_kind = 'rating'` alla mutazione `user_ratings`, o al motivo
 * per cui non se ne fa una. Le regole, nell'ordine in cui tagliano:
 *
 *   - **una reaction non è un voto** (`kind = 'reaction'`): la tabella di lookup era
 *     server-side ed è spenta con TV Time — si conserva grezza nell'export e nello staging,
 *     e il report la conta. Nessuna conversione inventata.
 *   - **l'episodio si risolve per `tvdb_episode_id` dalla mappa globale** (§6), la stessa già
 *     riempita dagli eventi della fase 3: un voto sta quasi sempre su un episodio visto,
 *     quindi la mappa lo sa già e non si spende nessuna chiamata TMDB. Fuori mappa o
 *     `not_found` → `non_risolto`, dichiarato.
 *   - **un voto già presente in app NON si sovrascrive** (`esistenti`, lapidi comprese):
 *     l'export è per definizione più vecchio di qualunque voto dato in app dopo, e un voto
 *     cancellato in app che l'import risuscitasse sarebbe l'import che disfa una scelta —
 *     stessa regola dell'`active` degli stati. È anche ciò che rende il re-import idempotente.
 *   - il `rating` deve stare in 1..10 (il CHECK della tabella): TV Time ammetteva lo 0, che
 *     nella scala a mezze stelle non esiste — fuori scala, dichiarato.
 */
export function buildRatingMutation(
  row: StagingRow,
  userId: string,
  mappa: Map<number, EpisodeMapEntry>,
  esistenti: Set<string>,
): BuildOutcome {
  const raw = row.raw ?? {}

  if (raw.kind !== 'star') return { mutation: null, skip: 'reaction_conservata' }

  const episodeId = Number(raw.tvdb_episode_id)
  if (!Number.isFinite(episodeId) || episodeId <= 0) {
    return { mutation: null, skip: 'senza_episodio' }
  }

  const rating = asInt(raw.star_rating)
  if (rating === null || rating < 1 || rating > 10) {
    return { mutation: null, skip: 'voto_fuori_scala' }
  }

  const voce = mappa.get(episodeId)
  if (!voce || voce.resolution !== 'found' || voce.tmdb_show_id === null) {
    return { mutation: null, skip: 'non_risolto' }
  }
  // I numeri vengono da TMDB, mai dall'export (§6): senza numerazione il CHECK di forma di
  // `user_ratings` (un voto a episodio senza numeri) rifiuterebbe comunque, e giustamente.
  const season = asInt(voce.season_number)
  const episode = asInt(voce.episode_number)
  if (season === null || episode === null) {
    return { mutation: null, skip: 'numerazione_mancante' }
  }

  if (esistenti.has(`${voce.tmdb_show_id}:${season}:${episode}`)) {
    return { mutation: null, skip: 'voto_gia_in_app' }
  }

  return {
    skip: null,
    mutation: {
      op: 'INSERT',
      table: 'user_ratings',
      record: {
        // Stesso obbligo delle altre tabelle: senza `user_id` combaciante, `apply_mutations`
        // scarta in silenzio verso `sync_rejected_mutations`.
        user_id: userId,
        media_type: 'episode',
        tmdb_id: voce.tmdb_show_id,
        season_number: season,
        episode_number: episode,
        rating,
      },
    },
  }
}

/**
 * Come `buildStatusBatch`, per i voti. Un doppione nello stesso lotto (lo stesso episodio
 * votato in due file dell'export) passa una volta sola: il secondo è `voto_gia_in_app` —
 * dopo il primo lo sarà alla lettera, e distinguere "già in app" da "già in questo lotto"
 * non cambierebbe nessuna decisione.
 */
export function buildRatingBatch(
  rows: StagingRow[],
  userId: string,
  mappa: Map<number, EpisodeMapEntry>,
  esistenti: Set<string>,
): BuiltBatch {
  const out: BuiltBatch = { mutations: [], written: [], skipped: [] }
  const emessi = new Set<string>(esistenti)

  for (const row of rows) {
    const { mutation, skip } = buildRatingMutation(row, userId, mappa, emessi)
    if (mutation) {
      const r = mutation.record
      emessi.add(`${r.tmdb_id}:${r.season_number}:${r.episode_number}`)
      out.mutations.push(mutation)
      out.written.push(row.row_index)
    } else {
      out.skipped.push({ row_index: row.row_index, reason: skip! })
    }
  }

  return out
}

/** Come `buildBatch`, per le righe di stato. `esistenti` = serie che hanno già una riga. */
export function buildStatusBatch(
  rows: StagingRow[],
  userId: string,
  esistenti: Set<number>,
): BuiltBatch {
  const out: BuiltBatch = { mutations: [], written: [], skipped: [] }

  for (const row of rows) {
    const { mutation, skip } = buildStatusMutation(row, userId, esistenti)
    if (mutation) {
      out.mutations.push(mutation)
      out.written.push(row.row_index)
    } else {
      out.skipped.push({ row_index: row.row_index, reason: skip! })
    }
  }

  return out
}

/** Costruisce il lotto e tiene separati gli indici scritti da quelli saltati, con la ragione. */
export function buildBatch(rows: StagingRow[], userId: string): BuiltBatch {
  const out: BuiltBatch = { mutations: [], written: [], skipped: [] }

  for (const row of rows) {
    const { mutation, skip } = buildEventMutation(row, userId)
    if (mutation) {
      out.mutations.push(mutation)
      out.written.push(row.row_index)
    } else {
      out.skipped.push({ row_index: row.row_index, reason: skip! })
    }
  }

  return out
}
