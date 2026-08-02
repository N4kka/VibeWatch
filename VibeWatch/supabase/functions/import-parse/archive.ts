// Lettura dell'archivio TV Time: ZIP → CSV → righe da mettere in staging.
//
// Separata da `index.ts` per un motivo pratico: `index.ts` chiama `serve()` appena importato, e
// quindi non è collaudabile. Qui invece si può puntare un test allo ZIP vero e contare le righe.
// È la parte che i test di `parsing.ts` non coprono — quelli sanno che le *regole* sono giuste,
// non che l'archivio si apra, che i file si chiamino così e che il CSV non abbia sorprese.

import { parse as parseCsv } from 'https://deno.land/std@0.224.0/csv/parse.ts'
import {
  BlobReader,
  configure,
  TextWriter,
  terminateWorkers,
  ZipReader,
} from 'https://deno.land/x/zipjs@v2.7.45/index.js'
import {
  assignRewatchIndex,
  dedupV1IntoV2,
  parseFavorites,
  parseRatings,
  parseSeriesStatuses,
  parseV1Events,
  parseV2Events,
  type ParsedFavorite,
  type ParsedRating,
  type Row,
  type SeriesStatus,
  type WatchEvent,
} from './parsing.ts'

// §7.1 — gli unici file che si guardano. Tutto il resto dell'export si ignora.
export const FILE_V2 = 'tracking-prod-records-v2.csv'
export const FILE_V1 = 'tracking-prod-records.csv'
export const RATING_FILES = [
  'ratings-3-prod-episode_votes.csv',
  'ratings-v2-prod-votes.csv',
  'ratings-prod-episode_votes.csv',
  'ratings-live-votes.csv',
]
// §7.1: gli stati per-serie — "watch later" e archivio — oltre ai flag di `user-series` in v2.
export const FILE_SPECIAL_STATUS = 'user_show_special_status.csv'
export const FILE_FOLLOWED = 'followed_tv_show.csv'
// §7.1: favorite-series/favorite-movies → candidati per i Favorites.
export const FILE_LISTS = 'lists-prod-lists.csv'

// zip.js decomprime su un pool di web worker. Comodo in un browser, sbagliato qui: il rilevatore
// di leak dei test lo ha colto subito ("a timer was started but never completed"), e in una Edge
// Function sarebbero worker che sopravvivono alla risposta su un runtime che le invocazioni si
// riciclano. La decompressione è comunque il costo minore del giro — la rete lo è di più.
configure({ useWebWorkers: false })

/** Legge i CSV che interessano da uno ZIP, ignorando percorsi e maiuscole. */
export async function readCsvEntries(zip: Blob, wanted: string[]): Promise<Map<string, Row[]>> {
  const reader = new ZipReader(new BlobReader(zip))
  const out = new Map<string, Row[]>()

  try {
    for (const entry of await reader.getEntries()) {
      if (entry.directory) continue
      const base = entry.filename.split('/').pop()?.toLowerCase() ?? ''
      const match = wanted.find((w) => w.toLowerCase() === base)
      if (!match || !entry.getData) continue

      const text = await entry.getData(new TextWriter())
      // `skipFirstRow` usa la prima riga come intestazione: è il formato di questi export.
      out.set(match, parseCsv(text, { skipFirstRow: true }) as Row[])
    }
  } finally {
    await reader.close()
    // Cintura oltre alle bretelle: se una versione futura di zip.js tornasse ai worker, questa
    // riga li chiude comunque invece di lasciarli appesi.
    await terminateWorkers()
  }

  return out
}

export interface BuiltRows {
  events: WatchEvent[]
  ratings: ParsedRating[]
  statuses: SeriesStatus[]
  favorites: ParsedFavorite[]
  favoriteMoviesUnsupported: number
  unusableV1: number
  droppedV1: number
}

/** Tutto il parsing puro, in un posto solo, così la parte di I/O resta leggibile. */
export function buildRows(files: Map<string, Row[]>): BuiltRows {
  const v2Rows = files.get(FILE_V2) ?? []
  const v2 = parseV2Events(v2Rows)
  const { events: v1All, unusable: unusableV1 } = parseV1Events(files.get(FILE_V1) ?? [])
  const { kept: v1, dropped: droppedV1 } = dedupV1IntoV2(v2, v1All)

  const events = assignRewatchIndex([...v2, ...v1])

  const ratings: ParsedRating[] = []
  for (const name of RATING_FILES) {
    const rows = files.get(name)
    if (rows) ratings.push(...parseRatings(rows, name))
  }

  // "Ha eventi" si decide sugli eventi TENUTI dopo il dedup, che sono quelli che diventeranno
  // `watch_events`: è rispetto a quelli che l'emissione di `active` deve non fare doppioni.
  const eventSeriesIds = new Set(
    events.map((e) => e.tvdb_series_id).filter((id) => id !== ''),
  )
  const statuses = parseSeriesStatuses(
    v2Rows,
    files.get(FILE_SPECIAL_STATUS) ?? [],
    files.get(FILE_FOLLOWED) ?? [],
    eventSeriesIds,
  )

  const { series: favorites, movies_unsupported: favoriteMoviesUnsupported } =
    parseFavorites(files.get(FILE_LISTS) ?? [])

  return { events, ratings, statuses, favorites, favoriteMoviesUnsupported, unusableV1, droppedV1 }
}
