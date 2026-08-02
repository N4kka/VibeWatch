import { assertEquals } from 'jsr:@std/assert@1'
import {
  assignRewatchIndex,
  dedupV1IntoV2,
  hasKnownNumbering,
  isSpecialEpisode,
  parseRatings,
  parseV1Events,
  parseV2Events,
  type Row,
  type WatchEvent,
} from './parsing.ts'

// --------------------------------------------------------------------------- v2

Deno.test('v2: prende watch-episode e rewatch-episode, ignora il resto', () => {
  const rows: Row[] = [
    { key: 'watch-episode-abc-1', s_id: '73739', ep_id: '4517291', season_number: '1', episode_number: '2', created_at: '2015-09-24T20:00:00Z', runtime: '3180' },
    { key: 'rewatch-episode-abc-2', s_id: '73739', ep_id: '4517291', season_number: '1', episode_number: '2', created_at: '2016-01-01T20:00:00Z' },
    { key: 'user-series-abc', s_id: '73739' },
    { key: 'follow-show-abc', s_id: '73739' },
  ]

  const events = parseV2Events(rows)

  assertEquals(events.length, 2)
  assertEquals(events.map((e) => e.event_kind), ['watch', 'rewatch'])
  assertEquals(events[0].runtime_seconds, 3180)
  assertEquals(events[0].origin, 'v2')
})

Deno.test('v2: un evento marcato in blocco non ha un orario attendibile', () => {
  const rows: Row[] = [
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '10', created_at: '2020-01-01T00:00:00Z', bulk_type: 'season' },
    { key: 'watch-episode-a-2', s_id: '1', ep_id: '11', created_at: '2020-01-01T00:00:00Z' },
    { key: 'watch-episode-a-3', s_id: '1', ep_id: '12', created_at: '2020-01-01T00:00:00Z', bulk_type: '   ' },
  ]

  const events = parseV2Events(rows)

  assertEquals(events[0].watched_at_precision, 'inferred', 'bulk_type valorizzato → inferred')
  assertEquals(events[1].watched_at_precision, 'exact')
  assertEquals(events[2].watched_at_precision, 'exact', 'solo spazi non è un bulk_type')
  assertEquals(events[2].bulk_type, null)
})

Deno.test('§1.3: is_special arriva dalla stagione, mai dal flag del file', () => {
  const rows: Row[] = [
    // Stagione 0 senza flag: è lo stesso uno speciale. Sull'export reale sono 113 eventi, e
    // leggerli dal flag faceva contare 8 speciali di One-Punch Man dentro il progresso.
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '10', season_number: '0', is_special: 'false' },
    // Flag 'true' in una stagione numerata: NON è uno speciale. Sono 15 eventi sull'export
    // reale, 13 dei quali di X Factor.
    { key: 'watch-episode-a-2', s_id: '1', ep_id: '11', season_number: '3', is_special: 'true' },
  ]

  const events = parseV2Events(rows)

  assertEquals(events[0].is_special, true)
  assertEquals(events[1].is_special, false)

  // Il flag grezzo non si butta: TV Time ci contava sopra e finisce in `external_ref`.
  assertEquals(events[0].tvtime_is_special_raw, false)
  assertEquals(events[1].tvtime_is_special_raw, true)
})

Deno.test('§6: episode_number 0 è una numerazione persa, non l episodio zero', () => {
  const rows: Row[] = [
    // Il caso Mario: id distinti, tutti senza numero, che fusi su (3,0) diventavano un
    // episodio solo. Qui restano due eventi separati, da risolvere su TMDB per id.
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '10', season_number: '3', episode_number: '0', runtime: '0' },
    { key: 'watch-episode-a-2', s_id: '1', ep_id: '11', season_number: '3', episode_number: '0', runtime: '0' },
    { key: 'watch-episode-a-3', s_id: '1', ep_id: '12', season_number: '1', episode_number: '1' },
    // In stagione 0 l'episodio 0 non è un problema: non entra comunque nel progresso.
    { key: 'watch-episode-a-4', s_id: '1', ep_id: '13', season_number: '0', episode_number: '0' },
  ]

  const events = parseV2Events(rows)

  assertEquals(events.map((e) => e.numbering_known), [false, false, true, true])
  assertEquals(
    new Set(events.filter((e) => !e.numbering_known).map((e) => e.tvdb_episode_id)).size,
    2,
    'due episodi senza numero restano due, identificati per id',
  )
})

// --------------------------------------------------------------------------- v1

Deno.test('v1: le righe senza id non sono eventi e vanno contate', () => {
  const rows: Row[] = [
    { entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '10', created_at: '2019-01-01' },
    { entity_type: 'episode', type: 'rewatch', series_id: '', episode_id: '' },
    { entity_type: 'episode', type: 'rewatch', series_id: '1' },
    { entity_type: 'show', type: 'watch', series_id: '1', episode_id: '11' },
    { entity_type: 'episode', type: 'follow', series_id: '1', episode_id: '12' },
  ]

  const { events, unusable } = parseV1Events(rows)

  assertEquals(events.length, 1)
  assertEquals(unusable, 2, 'i contatori senza id vanno nel report, non fatti sparire')
})

Deno.test('v1: la stagione 0 decide, come in v2', () => {
  const rows: Row[] = [
    { entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '10', season_number: '0' },
    { entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '11', season_number: '2' },
  ]

  const { events } = parseV1Events(rows)

  assertEquals(events[0].is_special, true)
  assertEquals(events[1].is_special, false)
})

// --------------------------------------------------------------------------- dedup

Deno.test('dedup §7.3: v2 vince, e da v1 resta solo ciò che v2 non ha', () => {
  const v2 = parseV2Events([
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '100' },
    { key: 'watch-episode-a-2', s_id: '1', ep_id: '101' },
  ])
  const { events: v1 } = parseV1Events([
    { entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '100' },
    { entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '999' },
  ])

  const { kept, dropped } = dedupV1IntoV2(v2, v1)

  assertEquals(dropped, 1)
  assertEquals(kept.map((e) => e.tvdb_episode_id), ['999'])
})

Deno.test('dedup §7.3: non si fonde per (stagione, episodio)', () => {
  // Il caso One-Punch Man: stesso numero di episodio, id diversi. Fondere per numero
  // cancellerebbe una visione vera.
  const v2 = parseV2Events([
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '500', season_number: '1', episode_number: '1' },
  ])
  const { events: v1 } = parseV1Events([
    { entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '900', season_number: '1', episode_number: '1' },
  ])

  const { kept, dropped } = dedupV1IntoV2(v2, v1)

  assertEquals(dropped, 0)
  assertEquals(kept.length, 1, 'stesso numero ma id diverso: è un altro episodio')
})

// -------------------------------------------------------------------- rewatch index

Deno.test('rewatch: 0 è la prima visione, poi in ordine cronologico', () => {
  const events = assignRewatchIndex(parseV2Events([
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '10', created_at: '2020-06-01' },
    { key: 'rewatch-episode-a-2', s_id: '1', ep_id: '10', created_at: '2018-01-01' },
    { key: 'rewatch-episode-a-3', s_id: '1', ep_id: '10', created_at: '2022-01-01' },
  ]))

  const perData = [...events].sort((a, b) => a.watched_at.localeCompare(b.watched_at))
  assertEquals(perData.map((e) => e.rewatch_index), [0, 1, 2])
  assertEquals(perData[0].dedup_key, 'tvtime:10:0')
  assertEquals(perData[2].dedup_key, 'tvtime:10:2')
})

Deno.test('rewatch: episodi diversi hanno indici indipendenti', () => {
  const events = assignRewatchIndex(parseV2Events([
    { key: 'watch-episode-a-1', s_id: '1', ep_id: '10', created_at: '2020-01-01' },
    { key: 'watch-episode-a-2', s_id: '1', ep_id: '11', created_at: '2020-01-02' },
  ]))

  assertEquals(events.map((e) => e.rewatch_index), [0, 0])
})

Deno.test('rewatch: a parità di timestamp l ordine è comunque deterministico', () => {
  // Se non lo fosse, lo stesso ZIP reimportato assegnerebbe dedup_key diverse e duplicherebbe —
  // esattamente ciò che il criterio 2 di §13 vieta.
  const costruisci = () => assignRewatchIndex([
    ...parseV1Events([{ entity_type: 'episode', type: 'watch', series_id: '1', episode_id: '10', created_at: '2020-01-01' }]).events,
    ...parseV2Events([{ key: 'watch-episode-a-1', s_id: '1', ep_id: '10', created_at: '2020-01-01' }]),
  ])

  const primo = costruisci().map((e) => `${e.origin}:${e.dedup_key}`).sort()
  const secondo = costruisci().map((e) => `${e.origin}:${e.dedup_key}`).sort()

  assertEquals(primo, secondo)
  assertEquals(primo, ['v1:tvtime:10:1', 'v2:tvtime:10:0'], 'v2 prima di v1')
})

// ---------------------------------------------------------------------------- voti

Deno.test('voti §7.5: X<=5 è una stella, X>=13 è una reaction', () => {
  const ratings = parseRatings([
    { vote_key: '4517291-user-3', episode_id: '4517291' },
    { vote_key: '4517291-user-1', episode_id: '4517291' },
    { vote_key: '4517291-user-27', episode_id: '4517291' },
  ], 'ratings-3-prod-episode_votes.csv')

  assertEquals(ratings[0].kind, 'star')
  assertEquals(ratings[0].star_rating, 6, '3 stelle su 5 → 6 su 10')
  assertEquals(ratings[0].tvtime_star_raw, 3, 'il grezzo si conserva per poter rifare la conversione')
  assertEquals(ratings[1].star_rating, 2)
  assertEquals(ratings[2].kind, 'reaction')
  assertEquals(ratings[2].reaction_id, 27)
  assertEquals(ratings[2].star_rating, null, 'una reaction non è un voto')
})

Deno.test('voti §7.5: la zona 6..12 non si indovina', () => {
  const ratings = parseRatings([
    { vote_key: 'a-b-8' },
    { vote_key: 'chiave-malformata' },
    { vote_key: '' },
  ], 'f.csv')

  assertEquals(ratings.map((r) => r.kind), ['undecodable', 'undecodable', 'undecodable'])
  assertEquals(ratings[0].raw_value, 8, 'il valore resta visibile nel report')
})

// ------------------------------------------------- confronto con l oracolo (dati veri)

/**
 * Rifà `assignRewatchIndex` sui 21.344 eventi dell'export reale e pretende gli stessi
 * `rewatch_index` e le stesse `dedup_key` prodotte da `build_oracle.py`.
 *
 * **Cosa questo test NON copre**, verificato invece che supposto: nel fixture ci sono 149 episodi
 * con più di un evento ma **zero collisioni di timestamp**, e solo 22 eventi su 21.344 vengono da
 * v1. Il tie-break a parità di data non è quindi esercitato da questi dati — invertirlo non fa
 * fallire questo test (provato). A coprirlo è il test sintetico qui sopra, che infatti fallisce.
 * Il fixture vale per l'ordinamento cronologico e la generazione delle chiavi su volume reale, non
 * per i pareggi.
 */
Deno.test('oracolo: gli indici di rewatch coincidono sui dati reali', async () => {
  const percorso = new URL('../../../oracle_fixture.json', import.meta.url)

  let fixture: { watch_events: Array<WatchEvent & { rewatch_index: number; dedup_key: string | null }> }
  try {
    fixture = JSON.parse(await Deno.readTextFile(percorso))
  } catch {
    console.warn('oracle_fixture.json non disponibile: confronto saltato')
    return
  }

  const attesi = fixture.watch_events
  assertEquals(attesi.length > 20_000, true, 'il fixture deve essere quello vero')

  // Si riparte dagli stessi eventi, privati di ciò che la funzione deve ricostruire.
  const ingresso: WatchEvent[] = attesi.map((e) => ({
    tvdb_series_id: String(e.tvdb_series_id),
    tvdb_episode_id: String(e.tvdb_episode_id),
    season_number: e.season_number,
    episode_number: e.episode_number,
    watched_at: e.watched_at,
    runtime_seconds: e.runtime_seconds,
    is_special: e.is_special,
    tvtime_is_special_raw: e.tvtime_is_special_raw,
    numbering_known: e.numbering_known,
    series_name: e.series_name,
    event_kind: e.event_kind,
    bulk_type: e.bulk_type,
    watched_at_precision: e.watched_at_precision,
    origin: e.origin,
  }))

  // Le due regole di §1.3 e §6 devono dare lo stesso esito qui e in `build_oracle.py`: se
  // divergono, l'oracolo smette di essere la specifica dell'importer e diventa un secondo
  // parere. Sul fixture vero sono 613 speciali e 195 eventi senza numerazione.
  for (const e of attesi) {
    assertEquals(e.is_special, isSpecialEpisode(e.season_number),
      `speciale non derivato dalla stagione: episodio ${e.tvdb_episode_id}`)
    assertEquals(e.numbering_known, hasKnownNumbering(e.season_number, e.episode_number),
      `numerazione non concorde: episodio ${e.tvdb_episode_id}`)
  }
  assertEquals(attesi.filter((e) => !e.numbering_known).length, 195)
  assertEquals(attesi.filter((e) => e.is_special).length, 613)

  assignRewatchIndex(ingresso)

  const chiave = (e: WatchEvent) =>
    `${e.tvdb_episode_id}|${e.watched_at}|${e.origin}|${e.event_kind}`

  const nostri = new Map<string, string[]>()
  for (const e of ingresso) {
    const bucket = nostri.get(chiave(e)) ?? []
    bucket.push(`${e.rewatch_index}:${e.dedup_key}`)
    nostri.set(chiave(e), bucket)
  }

  let confrontati = 0
  for (const atteso of attesi) {
    const bucket = nostri.get(chiave(atteso as WatchEvent))
    // Confronto esatto, non "contiene": senza collisioni di timestamp ogni chiave identifica un
    // evento solo. Se un fixture futuro ne portasse, questo fallisce invece di degradare in
    // silenzio a un confronto più debole — e a quel punto il pareggio va guardato davvero.
    assertEquals(bucket?.length, 1, `chiave non univoca: ${chiave(atteso as WatchEvent)}`)
    assertEquals(
      bucket?.[0],
      `${atteso.rewatch_index}:${atteso.dedup_key}`,
      `divergenza su ${atteso.dedup_key}`,
    )
    confrontati++
  }

  assertEquals(confrontati, attesi.length)
})

// ---------------------------------------------------------------------- stati serie

import { parseSeriesStatuses } from './parsing.ts'

Deno.test('stati §7.1: le tre sorgenti si uniscono, non si sceglie', () => {
  // `user-series` sa dell'archivio di A; il CSV `followed` sa di quello di B: sull'export vero
  // nessuna delle due liste contiene l'altra (57 vs 51), quindi si sommano.
  const v2: Row[] = [
    { key: 'user-series-a', s_id: '1', series_name: 'A', is_archived: 'true', is_followed: 'true' },
    { key: 'user-series-b', s_id: '2', series_name: 'B', is_followed: 'true' },
    { key: 'watch-episode-x-1', s_id: '3', ep_id: '30' }, // non è uno stato: si ignora
  ]
  const followed: Row[] = [{ tv_show_id: '2', tv_show_name: 'B', archived: '1', active: '0' }]
  const special: Row[] = [{ tv_show_id: '9', tv_show_name: 'C', status: 'for_later' }]

  const out = parseSeriesStatuses(v2, special, followed, new Set(['1', '2']))

  assertEquals(out.map((s) => `${s.tvdb_series_id}:${s.user_status}`), [
    '1:archived',
    '2:archived',
    '9:for_later',
  ])
})

Deno.test('stati: archived vince su for_later — archiviare dice "non ripresentarmela"', () => {
  const v2: Row[] = [
    { key: 'user-series-a', s_id: '1', is_for_later: 'true', is_archived: 'true' },
  ]
  const out = parseSeriesStatuses(v2, [], [], new Set())
  assertEquals(out.map((s) => s.user_status), ['archived'])
})

Deno.test('stati: active solo per le serie seguite SENZA eventi', () => {
  const v2: Row[] = [
    // Seguita e mai iniziata: senza questa emissione sparirebbe (nessun ricalcolo la creerà).
    { key: 'user-series-a', s_id: '1', series_name: 'Mai iniziata', is_followed: 'true' },
    // Seguita con eventi: la riga nasce dal ricalcolo, riscriverla `active` da qui
    // sovrascriverebbe uno stato che l'utente può aver già cambiato in app.
    { key: 'user-series-b', s_id: '2', series_name: 'Già vista', is_followed: 'true' },
    // Non seguita, senza flag, senza eventi: non c'è stato da importare.
    { key: 'user-series-c', s_id: '3', series_name: 'Niente', is_followed: 'false' },
  ]
  const out = parseSeriesStatuses(v2, [], [], new Set(['2']))
  assertEquals(out.map((s) => `${s.tvdb_series_id}:${s.user_status}`), ['1:active'])
  assertEquals(out[0].has_events, false)
})

Deno.test('stati: for_later resta anche con eventi — è una scelta, non un derivato', () => {
  const v2: Row[] = [
    { key: 'user-series-a', s_id: '1', is_for_later: 'true', is_followed: 'true' },
  ]
  const out = parseSeriesStatuses(v2, [], [], new Set(['1']))
  assertEquals(out.map((s) => s.user_status), ['for_later'])
  assertEquals(out[0].has_events, true)
})

Deno.test('stati: nel CSV followed una riga archiviata non conta come seguita', () => {
  const followed: Row[] = [
    { tv_show_id: '1', archived: '1', active: '1' },
    { tv_show_id: '2', archived: '0', active: '1' },
  ]
  const out = parseSeriesStatuses([], [], followed, new Set())
  assertEquals(out.map((s) => `${s.tvdb_series_id}:${s.user_status}`), ['1:archived', '2:active'])
})

Deno.test('stati: ordine per id numerico, riproducibile fra invocazioni', () => {
  const v2: Row[] = [
    { key: 'user-series-a', s_id: '100', is_archived: 'true' },
    { key: 'user-series-b', s_id: '20', is_archived: 'true' },
    { key: 'user-series-c', s_id: '3', is_archived: 'true' },
  ]
  const out = parseSeriesStatuses(v2, [], [], new Set())
  assertEquals(out.map((s) => s.tvdb_series_id), ['3', '20', '100'])
})

Deno.test('oracolo: gli stati sul fixture reale sono 57 archived, 28 for_later, 19 active', async () => {
  const percorso = new URL('../../../oracle_fixture.json', import.meta.url)
  let fixture: {
    watch_events: Array<{ tvdb_series_id: string }>
    tvtime_series_state: Record<string, {
      series_name: string | null
      is_for_later: boolean
      is_archived: boolean
      is_followed: boolean
    }>
    special_status: Array<{ tvdb_series_id: string; status: string; series_name: string | null }>
    followed_shows: Array<{ tvdb_series_id: string; archived: boolean; active: boolean }>
  }
  try {
    fixture = JSON.parse(await Deno.readTextFile(percorso))
  } catch {
    console.warn('oracle_fixture.json non disponibile: confronto saltato')
    return
  }

  // Il fixture porta i dati già decodificati (booleani, non stringhe CSV): si ricostruiscono le
  // righe come le leggerebbe `readCsvEntries`, così il confronto attraversa la stessa strada.
  const v2: Row[] = Object.entries(fixture.tvtime_series_state).map(([sid, s]) => ({
    key: `user-series-${sid}`,
    s_id: sid,
    series_name: s.series_name ?? undefined,
    is_for_later: String(s.is_for_later),
    is_archived: String(s.is_archived),
    is_followed: String(s.is_followed),
  }))
  const special: Row[] = fixture.special_status.map((r) => ({
    tv_show_id: r.tvdb_series_id,
    status: r.status,
    tv_show_name: r.series_name ?? undefined,
  }))
  const followed: Row[] = fixture.followed_shows.map((r) => ({
    tv_show_id: r.tvdb_series_id,
    archived: r.archived ? '1' : '0',
    active: r.active ? '1' : '0',
  }))
  const conEventi = new Set(fixture.watch_events.map((e) => e.tvdb_series_id))

  const out = parseSeriesStatuses(v2, special, followed, conEventi)

  const perStato = (st: string) => out.filter((s) => s.user_status === st).length
  assertEquals(perStato('archived'), 57)
  assertEquals(perStato('for_later'), 28)
  // Le 19 "seguite mai iniziate" sono la watchlist vera di chi arriva da TV Time — Prison
  // Break, The Orville — quelle che senza questa strada sparivano in silenzio.
  assertEquals(perStato('active'), 19)
  assertEquals(out.length, 104)
})

// --------------------------------------------------------------------------- favorites (§7.1)

import { parseFavorites } from './parsing.ts'

Deno.test('favorites: la slice Go si decodifica in id + data, in ordine di preferenza', () => {
  const { series, movies_unsupported } = parseFavorites([{
    s_key: 'favorite-series',
    objects: '[map[created_at:1.578991325e+09 id:362696 type:series] ' +
             'map[created_at:1.57515197e+09 id:300472 type:series] ' +
             'map[created_at:1.6e+09 id:99 type:movie]]',
  }])

  assertEquals(series.length, 2)
  assertEquals(series[0].tvdb_series_id, '300472', 'il piu vecchio viene prima')
  assertEquals(series[0].position, 0)
  assertEquals(series[1].tvdb_series_id, '362696')
  assertEquals(series[0].favorited_at?.startsWith('2019-11-30'), true,
    'epoch Go in secondi, non millisecondi')
  assertEquals(movies_unsupported, 1, 'un film fra le serie si conta, non si importa')
})

Deno.test('favorites: favorite-movies si dichiara non supportato, mai indovinato', () => {
  const { series, movies_unsupported } = parseFavorites([{
    s_key: 'favorite-movies',
    objects: '[map[created_at:1.6e+09 id:12345 type:movie] map[created_at:1.7e+09 id:678 type:movie]]',
  }])
  assertEquals(series.length, 0)
  assertEquals(movies_unsupported, 2)
})

Deno.test('favorites: un blocco senza id o fuori forma si scarta invece di inventare', () => {
  const { series } = parseFavorites([{
    s_key: 'favorite-series',
    objects: '[map[created_at:1.6e+09 type:series] map[created_at:x id:0 type:series] ' +
             'map[created_at:1.6e+09 id:70327 type:series]]',
  }])
  assertEquals(series.length, 1)
  assertEquals(series[0].tvdb_series_id, '70327')
})

Deno.test('favorites: altre righe del CSV (collection, liste custom) si ignorano', () => {
  const { series, movies_unsupported } = parseFavorites([
    { s_key: 'una-lista-custom', objects: '[map[created_at:1.6e+09 id:1 type:series]]' },
    { lists: '...', s_key: '' },
  ])
  assertEquals(series.length, 0)
  assertEquals(movies_unsupported, 0)
})
