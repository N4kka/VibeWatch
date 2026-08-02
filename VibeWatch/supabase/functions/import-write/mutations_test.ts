import { assertEquals } from 'jsr:@std/assert@1'
import {
  buildBatch,
  buildEventMutation,
  buildRatingBatch,
  buildRatingMutation,
  type EpisodeMapEntry,
  isSpecialEpisode,
  runtimeOrNull,
  type StagingRow,
  toUtcIso,
} from './mutations.ts'

const UTENTE = '00000000-0000-4000-8000-000000000001'

function riga(
  raw: Record<string, unknown>,
  resolved: Record<string, unknown> | null,
  rowIndex = 0,
): StagingRow {
  return { row_index: rowIndex, raw, resolved, status: 'resolved' }
}

const RAW_BASE = {
  row_kind: 'event',
  tvdb_series_id: '1399',
  tvdb_episode_id: '3254641',
  season_number: 1,
  episode_number: 1,
  watched_at: '2019-07-02 05:58:55',
  runtime_seconds: 3600,
  rewatch_index: 0,
  dedup_key: 'tvtime:3254641:0',
  watched_at_precision: 'exact',
  tvtime_is_special_raw: false,
  bulk_type: null,
}

// --------------------------------------------------------------------------- stagione

Deno.test('§6: stagione ed episodio vengono da TMDB, mai dall export', () => {
  // L'export dice S1E1, TMDB dice S2E5: vince TMDB. È il caso Digimon/One-Punch Man, dove i due
  // sistemi numerano diversamente e fidarsi dell'export inventa episodi.
  const { mutation } = buildEventMutation(
    riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 2, episode_number: 5 }),
    UTENTE,
  )

  assertEquals(mutation?.record.season_number, 2)
  assertEquals(mutation?.record.episode_number, 5)
  // ...e l'id di origine resta, così il lavoro si può rifare.
  assertEquals(
    (mutation?.record.external_ref as Record<string, unknown>).tvdb_episode_id,
    '3254641',
  )
})

Deno.test('§1.3: is_special si deriva dalla stagione RISOLTA, non da quella dell export', () => {
  // L'export lo dà in stagione 3 e non speciale; TMDB lo mette in stagione 0.
  const { mutation } = buildEventMutation(
    riga(
      { ...RAW_BASE, season_number: 3, tvtime_is_special_raw: false },
      { tmdb_show_id: 1399, season_number: 0, episode_number: 2 },
    ),
    UTENTE,
  )

  assertEquals(mutation?.record.is_special, true,
    'la stagione autorevole dopo il resolving è quella di TMDB')
  assertEquals(
    (mutation?.record.external_ref as Record<string, unknown>).tvtime_is_special,
    false,
    'il criterio di TV Time si conserva, ma non decide',
  )
})

Deno.test('is_special_episode è la stessa regola di Postgres e del parser', () => {
  assertEquals(isSpecialEpisode(0), true)
  assertEquals(isSpecialEpisode(1), false)
  assertEquals(isSpecialEpisode(null), true, 'coalesce(season, 0) = 0')
})

// --------------------------------------------------------------------------- user_id

Deno.test('il record porta sempre user_id, o apply_mutations lo scarta in silenzio', () => {
  const { mutation } = buildEventMutation(
    riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 1, episode_number: 1 }),
    UTENTE,
  )
  assertEquals(mutation?.record.user_id, UTENTE)
})

// --------------------------------------------------------------------------- tempo

Deno.test('i timestamp dell export sono UTC e il fuso si scrive esplicito', () => {
  assertEquals(toUtcIso('2019-07-02 05:58:55'), '2019-07-02T05:58:55Z')
  assertEquals(toUtcIso('2019-07-02T05:58:55Z'), '2019-07-02T05:58:55Z', 'già esplicito: invariato')
  assertEquals(toUtcIso('2019-07-02T05:58:55+02:00'), '2019-07-02T05:58:55+02:00')
  assertEquals(toUtcIso(''), null)
  assertEquals(toUtcIso('non una data'), null)
})

Deno.test('§13.7: runtime 0 significa "non lo so", e va scritto null', () => {
  // Sull export reale sono 309 eventi, le stesse righe orfane che hanno perso la numerazione.
  // A 0 sporcherebbero il totale di tempo di visione; a null il totale usa il catalogo TMDB.
  assertEquals(runtimeOrNull(0), null)
  assertEquals(runtimeOrNull(null), null)
  assertEquals(runtimeOrNull(undefined), null)
  assertEquals(runtimeOrNull(1440), 1440)

  const { mutation } = buildEventMutation(
    riga({ ...RAW_BASE, runtime_seconds: 0 },
      { tmdb_show_id: 1399, season_number: 1, episode_number: 1 }),
    UTENTE,
  )
  assertEquals(mutation?.record.runtime_seconds, null)
})

// ------------------------------------------------------------------- cosa non si scrive

Deno.test('§7.4: ciò che non si può scrivere torna con la ragione, non approssimato', () => {
  const casi: Array<[string, StagingRow, string]> = [
    ['non risolto', riga(RAW_BASE, null), 'non_risolto'],
    [
      'senza show',
      riga(RAW_BASE, { season_number: 1, episode_number: 1 }),
      'show_mancante',
    ],
    [
      // Il caso Mario: numerazione persa e non recuperata da TMDB. Il CHECK
      // `watch_events_shape` la rifiuterebbe comunque; inventarla è ciò che §7.4 vieta.
      'numerazione ancora ignota',
      riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 3, episode_number: null }),
      'numerazione_mancante',
    ],
    [
      'senza dedup_key',
      riga({ ...RAW_BASE, dedup_key: null },
        { tmdb_show_id: 1399, season_number: 1, episode_number: 1 }),
      'senza_dedup_key',
    ],
    [
      'data illeggibile',
      riga({ ...RAW_BASE, watched_at: '' },
        { tmdb_show_id: 1399, season_number: 1, episode_number: 1 }),
      'numerazione_mancante',
    ],
  ]

  for (const [nome, row, atteso] of casi) {
    const { mutation, skip } = buildEventMutation(row, UTENTE)
    assertEquals(mutation, null, `${nome}: non deve produrre una mutazione`)
    assertEquals(skip, atteso, nome)
  }
})

Deno.test('una numerazione mancante non diventa mai episodio 0', () => {
  // `Number(null)` è 0 e `Number('')` è 0, entrambi interi: senza guardia esplicita una stagione
  // o un episodio assenti si trasformano in un episodio vero, e §1.3 leggerebbe quello zero come
  // "speciale". È la trappola di `episode_number = 0` che si ripresenta un passaggio più in là.
  for (const mancante of [null, undefined, '', '   ']) {
    const senzaEpisodio = buildEventMutation(
      riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 1, episode_number: mancante }),
      UTENTE,
    )
    assertEquals(senzaEpisodio.mutation, null, `episodio ${JSON.stringify(mancante)}`)

    const senzaStagione = buildEventMutation(
      riga(RAW_BASE, { tmdb_show_id: 1399, season_number: mancante, episode_number: 1 }),
      UTENTE,
    )
    assertEquals(senzaStagione.mutation, null, `stagione ${JSON.stringify(mancante)}`)
  }

  // Lo zero vero di TMDB resta valido: la stagione 0 esiste e ha episodi.
  const specialeVero = buildEventMutation(
    riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 0, episode_number: 0 }),
    UTENTE,
  )
  assertEquals(specialeVero.mutation?.record.is_special, true)
  assertEquals(specialeVero.mutation?.record.episode_number, 0)
})

Deno.test('criterio 2 di §13: la dedup_key sopravvive intatta fino alla mutazione', () => {
  const { mutation } = buildEventMutation(
    riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 1, episode_number: 1 }),
    UTENTE,
  )
  assertEquals(mutation?.record.dedup_key, 'tvtime:3254641:0')
  assertEquals(mutation?.record.source, 'import_tvtime')
})

// ----------------------------------------------------------------------------- lotto

Deno.test('il lotto tiene separati gli scritti dai saltati, con gli indici giusti', () => {
  const rows = [
    riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 1, episode_number: 1 }, 0),
    riga(RAW_BASE, null, 1),
    riga({ ...RAW_BASE, dedup_key: 'tvtime:9:0' },
      { tmdb_show_id: 1399, season_number: 1, episode_number: 2 }, 2),
    riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 1, episode_number: null }, 3),
  ]

  const { mutations, written, skipped } = buildBatch(rows, UTENTE)

  assertEquals(mutations.length, 2)
  assertEquals(written, [0, 2])
  assertEquals(skipped, [
    { row_index: 1, reason: 'non_risolto' },
    { row_index: 3, reason: 'numerazione_mancante' },
  ])
  // Nessuna riga si perde per strada: ogni indice sta di qua o di là, mai in nessuno dei due.
  assertEquals(written.length + skipped.length, rows.length)
})

Deno.test("l'involucro è quello che apply_mutations sa leggere", () => {
  const { mutations } = buildBatch(
    [riga(RAW_BASE, { tmdb_show_id: 1399, season_number: 1, episode_number: 1 })],
    UTENTE,
  )
  assertEquals(mutations[0].op, 'INSERT')
  assertEquals(mutations[0].table, 'watch_events')
  assertEquals(mutations[0].record.media_type, 'tv')
})

// ---------------------------------------------------------------------- stati serie

import { buildStatusBatch, buildStatusMutation } from './mutations.ts'

const rigaStato = (
  status: string,
  resolved: Record<string, unknown> | null,
  rowIndex = 0,
): StagingRow => ({
  row_index: rowIndex,
  raw: { row_kind: 'status', tvdb_series_id: '73739', user_status: status },
  resolved,
  status: 'resolved',
})

Deno.test('stati: la mutazione è un upsert di tv_show_state con la sola scelta dell utente', () => {
  const { mutation, skip } = buildStatusMutation(
    rigaStato('for_later', { tmdb_show_id: 1399 }), UTENTE, new Set(),
  )
  assertEquals(skip, null)
  assertEquals(mutation?.table, 'tv_show_state')
  assertEquals(mutation?.record, {
    user_id: UTENTE,
    tmdb_show_id: 1399,
    user_status: 'for_later',
  })
})

Deno.test('stati: for_later e archived sovrascrivono, è lo stato che si sta importando', () => {
  const esistenti = new Set([1399])
  for (const stato of ['for_later', 'archived']) {
    const { mutation, skip } = buildStatusMutation(
      rigaStato(stato, { tmdb_show_id: 1399 }), UTENTE, esistenti,
    )
    assertEquals(skip, null, stato)
    assertEquals(mutation?.record.user_status, stato)
  }
})

Deno.test('stati: un active non sovrascrive una riga che esiste già', () => {
  // `active` significa solo "seguita mai iniziata, falla esistere": se la riga c'è, l'utente
  // può averle già dato uno stato in app, e riportarla ad active disferebbe quella scelta.
  const { mutation, skip } = buildStatusMutation(
    rigaStato('active', { tmdb_show_id: 1399 }), UTENTE, new Set([1399]),
  )
  assertEquals(mutation, null)
  assertEquals(skip, 'stato_gia_in_app')

  const via = buildStatusMutation(rigaStato('active', { tmdb_show_id: 1399 }), UTENTE, new Set())
  assertEquals(via.mutation?.record.user_status, 'active')
})

Deno.test('stati: non risolto, senza show o con uno stato ignoto non si scrive approssimato', () => {
  assertEquals(buildStatusMutation(rigaStato('for_later', null), UTENTE, new Set()).skip,
    'non_risolto')
  assertEquals(buildStatusMutation(rigaStato('for_later', {}), UTENTE, new Set()).skip,
    'show_mancante')
  // `dropped` è legittimo nella CHECK ma l'import non lo emette: se compare è un difetto del
  // parser, e va dichiarato invece di scritto.
  assertEquals(buildStatusMutation(rigaStato('dropped', { tmdb_show_id: 1 }), UTENTE, new Set()).skip,
    'stato_non_valido')
})

Deno.test('stati: il lotto separa scritti e saltati come per gli eventi', () => {
  const rows = [
    rigaStato('for_later', { tmdb_show_id: 10 }, 0),
    rigaStato('active', { tmdb_show_id: 20 }, 1),
    rigaStato('archived', null, 2),
  ]
  const { mutations, written, skipped } = buildStatusBatch(rows, UTENTE, new Set([20]))

  assertEquals(mutations.length, 1)
  assertEquals(written, [0])
  assertEquals(skipped, [
    { row_index: 1, reason: 'stato_gia_in_app' },
    { row_index: 2, reason: 'non_risolto' },
  ])
  assertEquals(written.length + skipped.length, rows.length)
})

// --------------------------------------------------------------------------- voti (§7.5)

function rigaVoto(
  raw: Record<string, unknown>,
  rowIndex = 0,
): StagingRow {
  return {
    row_index: rowIndex,
    raw: { row_kind: 'rating', ...raw },
    resolved: null,
    status: 'pending',
  }
}

const MAPPA_VOTI = new Map<number, EpisodeMapEntry>([
  [4517291, { resolution: 'found', tmdb_show_id: 100, season_number: 2, episode_number: 5 }],
  [4517292, { resolution: 'not_found', tmdb_show_id: null, season_number: null, episode_number: null }],
  [4517293, { resolution: 'found', tmdb_show_id: 100, season_number: null, episode_number: null }],
])

Deno.test('voti: una stella risolta diventa una mutazione user_ratings con i numeri di TMDB', () => {
  const { mutation, skip } = buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517291', star_rating: 6 }),
    UTENTE, MAPPA_VOTI, new Set())

  assertEquals(skip, null)
  assertEquals(mutation?.table, 'user_ratings')
  assertEquals(mutation?.record.user_id, UTENTE, 'senza user_id apply_mutations scarta in silenzio')
  assertEquals(mutation?.record.media_type, 'episode')
  assertEquals(mutation?.record.tmdb_id, 100)
  assertEquals(mutation?.record.season_number, 2, 'la stagione viene da TMDB (§6)')
  assertEquals(mutation?.record.episode_number, 5)
  assertEquals(mutation?.record.rating, 6)
})

Deno.test('voti: una reaction non è un voto — si conserva, non si converte', () => {
  const { mutation, skip } = buildRatingMutation(
    rigaVoto({ kind: 'reaction', tvdb_episode_id: '4517291', reaction_id: 27 }),
    UTENTE, MAPPA_VOTI, new Set())
  assertEquals(mutation, null)
  assertEquals(skip, 'reaction_conservata')
})

Deno.test('voti: fuori mappa, not_found o senza numerazione non si scrive approssimato', () => {
  assertEquals(buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '999999', star_rating: 6 }),
    UTENTE, MAPPA_VOTI, new Set()).skip, 'non_risolto', 'fuori mappa')
  assertEquals(buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517292', star_rating: 6 }),
    UTENTE, MAPPA_VOTI, new Set()).skip, 'non_risolto', 'not_found in mappa')
  assertEquals(buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517293', star_rating: 6 }),
    UTENTE, MAPPA_VOTI, new Set()).skip, 'numerazione_mancante',
    'serie risolta ma senza numeri: il CHECK di forma rifiuterebbe comunque')
  assertEquals(buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: null, star_rating: 6 }),
    UTENTE, MAPPA_VOTI, new Set()).skip, 'senza_episodio')
})

Deno.test('voti: un voto già in app non si sovrascrive — vale anche per le lapidi', () => {
  const { mutation, skip } = buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517291', star_rating: 6 }),
    UTENTE, MAPPA_VOTI, new Set(['100:2:5']))
  assertEquals(mutation, null)
  assertEquals(skip, 'voto_gia_in_app')
})

Deno.test('voti: lo 0 di TV Time è fuori dalla scala 1-10 e si dichiara', () => {
  assertEquals(buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517291', star_rating: 0 }),
    UTENTE, MAPPA_VOTI, new Set()).skip, 'voto_fuori_scala')
  assertEquals(buildRatingMutation(
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517291', star_rating: null }),
    UTENTE, MAPPA_VOTI, new Set()).skip, 'voto_fuori_scala')
})

Deno.test('voti: lo stesso episodio votato due volte nel lotto passa una volta sola', () => {
  const rows = [
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517291', star_rating: 6 }, 0),
    rigaVoto({ kind: 'star', tvdb_episode_id: '4517291', star_rating: 8 }, 1),
    rigaVoto({ kind: 'reaction', tvdb_episode_id: '4517291', reaction_id: 27 }, 2),
  ]
  const { mutations, written, skipped } = buildRatingBatch(rows, UTENTE, MAPPA_VOTI, new Set())

  assertEquals(mutations.length, 1)
  assertEquals(mutations[0].record.rating, 6, 'vince il primo, deterministico per row_index')
  assertEquals(written, [0])
  assertEquals(skipped, [
    { row_index: 1, reason: 'voto_gia_in_app' },
    { row_index: 2, reason: 'reaction_conservata' },
  ])
  assertEquals(written.length + skipped.length, rows.length)
})
