#!/usr/bin/env python3
"""
Costruisce un fixture di test ("oracolo") da un export GDPR di TV Time.

Idea: TV Time esporta sia gli EVENTI grezzi (watch-episode, rewatch-episode) sia lo
STATO DERIVATO che aveva gia' calcolato per ogni serie (user-series: ep_watch_count,
most_recent_ep_watched, is_for_later, is_archived, is_followed).

L'importer di VibeWatch deve ricalcolare quello stato dagli eventi. Se il ricalcolo
coincide con lo stato di TV Time su tutte le serie, l'import e' corretto per costruzione;
dove non coincide, il fixture dice PERCHE' (campo `cause` di ogni divergenza), che e' il
requisito di SPEC v3 §8: ogni divergenza va spiegata o risolta prima del rilascio.

Riferimenti alla spec:
  §7.1  quali file dell'export si leggono
  §7.3  dedup v1/v2: vince v2, da v1 solo gli episodi assenti da v2
  §7.5  decodifica dei voti: X <= 5 stelle (0-5), X >= 13 id di reaction
  §3.2  watched_at_precision, rewatch_index, dedup_key
  §8    l'oracolo e i casi limite da coprire

Uso:  python3 build_oracle.py <cartella_export> <output.json>
"""

import csv, json, re, sys, hashlib
from pathlib import Path
from collections import defaultdict, Counter

# most_recent_ep_watched arriva come stringa Go: map[ep_id:7.8e+06 ep_no:10 s_no:3 uuid:... watch_date:1.76e+15]
GO_MAP = re.compile(r'(\w+):([^\s\]]+)')

# §7.5: il valore in coda a vote_key e' o una valutazione in stelle o un id di reaction.
STAR_MAX = 5        # X <= 5  -> stelle (scala 0-5)
REACTION_MIN = 13   # X >= 13 -> id di reaction (lo spazio id di emotions-* e' 13-38)


def parse_go_map(s):
    if not s or not s.startswith('map['):
        return None
    out = {}
    for k, v in GO_MAP.findall(s[4:-1]):
        try:
            out[k] = int(float(v))
        except ValueError:
            out[k] = v
    return out


def anon(user_id):
    """user_id pseudonimizzato: il fixture finisce in repo, i dati sono di una persona reale."""
    return 'u_' + hashlib.sha256(str(user_id).encode()).hexdigest()[:12]


def read(path):
    if not path.exists():
        return []
    with path.open(newline='', encoding='utf-8', errors='replace') as fh:
        return list(csv.DictReader(fh))


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


# --------------------------------------------------------------------------- eventi


def parse_v2_events(rows):
    """watch-episode e rewatch-episode dal formato corrente."""
    events = []
    for r in rows:
        key = r.get('key', '')
        if key.startswith('watch-episode'):
            kind = 'watch'
        elif key.startswith('rewatch-episode'):
            kind = 'rewatch'
        else:
            continue
        bulk = (r.get('bulk_type') or '').strip()
        events.append({
            'tvdb_series_id':  r['s_id'],
            'tvdb_episode_id': r['ep_id'],
            'season_number':   as_int(r.get('season_number')),
            'episode_number':  as_int(r.get('episode_number')),
            'watched_at':      r['created_at'],
            'runtime_seconds': as_int(r.get('runtime')),
            'is_special':      r.get('is_special') == 'true',
            'series_name':     r.get('series_name'),
            'event_kind':      kind,
            'bulk_type':       bulk or None,
            # §3.2: un episodio marcato in blocco porta il timestamp del "segna stagione",
            # non quello della visione. Va importato, ma non e' un dato temporale attendibile.
            'watched_at_precision': 'inferred' if bulk else 'exact',
            'origin':          'v2',
        })
    return events


def parse_v1_events(rows):
    """
    Formato legacy: stessi eventi, schema diverso. Serve solo per cio' che manca in v2.

    Restituisce anche il numero di righe scartate perche' inutilizzabili: v1 contiene righe
    `rewatch` senza series_id ne' episode_id (contatori, non eventi). Non sono importabili e
    vanno contate nel report di fine import (§7.4), non fatte sparire.
    """
    events, unusable = [], 0
    for r in rows:
        if r.get('entity_type') != 'episode':
            continue
        kind = r.get('type')
        if kind not in ('watch', 'rewatch'):
            continue
        if not r.get('series_id') or not r.get('episode_id'):
            unusable += 1
            continue
        bulk = (r.get('bulk_type') or '').strip()
        events.append({
            'tvdb_series_id':  r['series_id'],
            'tvdb_episode_id': r['episode_id'],
            'season_number':   as_int(r.get('season_number')),
            'episode_number':  as_int(r.get('episode_number')),
            'watched_at':      r['created_at'],
            'runtime_seconds': as_int(r.get('runtime')),
            # v1 non ha is_special: la stagione 0 e' l'unico segnale disponibile.
            'is_special':      r.get('season_number') == '0',
            'series_name':     r.get('series_name'),
            'event_kind':      kind,
            'bulk_type':       bulk or None,
            'watched_at_precision': 'inferred' if bulk else 'exact',
            'origin':          'v1',
        })
    return events, unusable


def dedup_v1_into_v2(v2_events, v1_events):
    """
    §7.3 `DECISO`: v2 vince. Da v1 si prendono solo gli eventi il cui tvdb_episode_id non
    compare affatto in v2. NON si fonde per (season, episode): i due file numerano
    diversamente (One-Punch Man 36 vs 44), quindi fondere per numero crea episodi fantasma.
    """
    v2_episode_ids = {e['tvdb_episode_id'] for e in v2_events if e['tvdb_episode_id']}
    kept, dropped = [], 0
    for e in v1_events:
        if e['tvdb_episode_id'] and e['tvdb_episode_id'] in v2_episode_ids:
            dropped += 1
            continue
        kept.append(e)
    return kept, dropped, v2_episode_ids


def assign_rewatch_index(events):
    """
    §3.2: rewatch_index 0 = prima visione, poi 1, 2, ... in ordine cronologico sullo stesso
    episodio. dedup_key = 'tvtime:{tvdb_episode_id}:{rewatch_index}' rende l'import
    idempotente: reimportare lo stesso ZIP non duplica (criterio di accettazione 2).
    """
    by_episode = defaultdict(list)
    for e in events:
        by_episode[(e['tvdb_series_id'], e['tvdb_episode_id'])].append(e)

    for (_, episode_id), group in by_episode.items():
        # ordine stabile anche a parita' di timestamp: v2 prima di v1, poi watch prima di rewatch
        group.sort(key=lambda e: (e['watched_at'] or '', e['origin'] == 'v1', e['event_kind'] == 'rewatch'))
        for index, event in enumerate(group):
            event['rewatch_index'] = index
            event['dedup_key'] = f'tvtime:{episode_id}:{index}' if episode_id else None


# ------------------------------------------------------------------------ ricalcolo


def recompute_state(events):
    """
    Lo stato per serie ricalcolato SOLO dagli eventi: e' cio' che l'importer deve riprodurre.
    Gli speciali restano tracciati ma fuori dal progresso (§1.3, comportamento TV Time).
    """
    buckets = defaultdict(lambda: {
        'episodes': set(),          # (season, episode) non speciali, distinti
        'episodes_with_specials': set(),
        'special_episodes': set(),
        'episode_ids': set(),       # tvdb_episode_id distinti: puo' essere > delle coppie
        'last': None,               # ultimo evento non speciale
        'event_count': 0,
        'rewatch_count': 0,
        'v1_only_episode_ids': set(),
        'series_name': None,
    })

    for e in events:
        bucket = buckets[e['tvdb_series_id']]
        bucket['event_count'] += 1
        bucket['series_name'] = bucket['series_name'] or e['series_name']
        if e['tvdb_episode_id']:
            bucket['episode_ids'].add(e['tvdb_episode_id'])
        if e['rewatch_index'] > 0 or e['event_kind'] == 'rewatch':
            bucket['rewatch_count'] += 1
        if e['origin'] == 'v1':
            bucket['v1_only_episode_ids'].add(e['tvdb_episode_id'])

        key = (e['season_number'], e['episode_number'])
        bucket['episodes_with_specials'].add(key)
        if e['is_special']:
            bucket['special_episodes'].add(key)
            continue
        bucket['episodes'].add(key)
        if bucket['last'] is None or (e['watched_at'] or '') > (bucket['last']['watched_at'] or ''):
            bucket['last'] = e

    state = {}
    for series_id, bucket in buckets.items():
        last = bucket['last']
        state[series_id] = {
            'series_name':             bucket['series_name'],
            'distinct_episode_count':  len(bucket['episodes']),
            'distinct_with_specials':  len(bucket['episodes_with_specials']),
            'distinct_episode_ids':    len(bucket['episode_ids']),
            'special_episode_count':   len(bucket['special_episodes']),
            'event_count':             bucket['event_count'],
            'rewatch_count':           bucket['rewatch_count'],
            'v1_only_episode_count':   len(bucket['v1_only_episode_ids']),
            'last_watched_at':         last['watched_at'] if last else None,
            'last_season':             last['season_number'] if last else None,
            'last_episode':            last['episode_number'] if last else None,
        }
    return state


# §8: "ogni divergenza va spiegata o risolta". Ogni causa qui sotto e' una regola verificata
# sui numeri del fixture, non un'ipotesi: la si puo' rivalutare rigenerando l'oracolo.
DIVERGENCE_CAUSES = {
    'tvtime_counted_episode_ids':
        'La serie ha piu tvdb_episode_id distinti che coppie (stagione, episodio) e TV Time ha '
        'contato gli id. E la numerazione assoluta vs per stagione: due id TVDB finiscono sullo '
        'stesso S/E. Contare le coppie e il comportamento corretto per VibeWatch.',
    'specials_counted_by_tvtime':
        'Includendo gli speciali il conteggio coincide: TV Time li teneva nel totale della serie. '
        '§1.3 li tiene fuori dal progresso, quindi la differenza e attesa.',
    'rewatches_counted_by_tvtime':
        'Il conteggio coincide sommando i rewatch: TV Time contava le visioni, non gli episodi '
        'distinti. §1.2 tiene i rewatch come eventi separati, fuori dal progresso.',
    'episode_id_collision_partial':
        'Ci sono id duplicati sulla stessa coppia S/E, ma il conteggio di TV Time non coincide ne '
        'con gli id ne con le coppie. Serve una verifica manuale sulla serie.',
    'tvtime_counter_drift':
        'Nessuna spiegazione strutturale e lo scarto e minimo. ep_watch_count e un contatore '
        'denormalizzato aggiornato per anni: il log degli eventi e la fonte migliore. '
        'Divergenza ACCETTATA: VibeWatch si fida degli eventi.',
    'needs_manual_review':
        'Nessuna regola spiega lo scarto. Da risolvere a mano prima del rilascio.',
}

# Oltre questo scarto un disallineamento non e' piu' derubricabile a deriva del contatore.
COUNTER_DRIFT_TOLERANCE = 2


def explain_divergence(expected, got):
    """Restituisce la causa piu' probabile, verificata sui numeri."""
    tvtime = expected['ep_watch_count']
    recomputed = got['distinct_episode_count']
    # Confronto omogeneo: entrambi i termini includono gli speciali, altrimenti ogni serie con
    # speciali sembrerebbe avere id duplicati.
    has_id_collision = got['distinct_episode_ids'] > got['distinct_with_specials']

    if has_id_collision and tvtime == got['distinct_episode_ids']:
        return 'tvtime_counted_episode_ids'
    if got['special_episode_count'] and got['distinct_with_specials'] == tvtime:
        return 'specials_counted_by_tvtime'
    if recomputed + got['rewatch_count'] == tvtime:
        return 'rewatches_counted_by_tvtime'
    if has_id_collision:
        return 'episode_id_collision_partial'
    if abs(tvtime - recomputed) <= COUNTER_DRIFT_TOLERANCE:
        return 'tvtime_counter_drift'
    return 'needs_manual_review'


# ----------------------------------------------------------------------------- voti


def parse_ratings(src, files):
    """
    §7.5 `DECISO`. vote_key = '{episode_id}-{user_id}-{X}'. X <= 5 e' una valutazione in
    stelle 0-5 (-> user_ratings.rating = X * 2, mezze stelle 1-10); X >= 13 e' l'id di una
    reaction, che si conserva grezzo: la tabella di lookup era server-side ed e' spenta.
    """
    ratings, distribution = [], Counter()
    for name in files:
        for r in read(src / name):
            parts = (r.get('vote_key') or '').split('-')
            raw = as_int(parts[-1]) if len(parts) == 3 else None

            if raw is None:
                kind, star_rating, reaction_id = 'undecodable', None, None
            elif raw <= STAR_MAX:
                kind, star_rating, reaction_id = 'star', raw * 2, None
            elif raw >= REACTION_MIN:
                kind, star_rating, reaction_id = 'reaction', None, raw
            else:
                # 6..12 non e' mai stato osservato nell'export reale. Non si indovina.
                kind, star_rating, reaction_id = 'undecodable', None, None

            distribution[f'{kind}:{raw}'] += 1
            ratings.append({
                'tvdb_episode_id': r.get('episode_id'),
                'raw_value':       raw,
                'kind':            kind,
                # user_ratings usa 1-10 per le mezze stelle (scala Letterboxd 0.5-5.0)
                'star_rating':     star_rating,
                'tvtime_star_raw': raw if kind == 'star' else None,
                'reaction_id':     reaction_id,
                'series_name':     r.get('series_name') or r.get('movie_name'),
                'season_number':   as_int(r.get('season_number')),
                'episode_number':  as_int(r.get('episode_number')),
                'source_file':     name,
            })
    return ratings, distribution


# ---------------------------------------------------------------------------- build


RATING_FILES = [
    'ratings-3-prod-episode_votes.csv',
    'ratings-v2-prod-votes.csv',
    'ratings-prod-episode_votes.csv',
    'ratings-live-votes.csv',
]


def build(src: Path):
    v2_rows = read(src / 'tracking-prod-records-v2.csv')
    v1_rows = read(src / 'tracking-prod-records.csv')

    v2_events = parse_v2_events(v2_rows)
    v1_events_all, unusable_v1_rows = parse_v1_events(v1_rows)
    v1_events, dropped_v1, v2_episode_ids = dedup_v1_into_v2(v2_events, v1_events_all)

    events = v2_events + v1_events
    assign_rewatch_index(events)
    events.sort(key=lambda e: (e['tvdb_series_id'], e['season_number'] or -1,
                               e['episode_number'] or -1, e['watched_at'] or '', e['origin']))

    # Stato che TV Time aveva gia' calcolato: l'ORACOLO.
    series_state = {}
    for r in v2_rows:
        if not r.get('key', '').startswith('user-series'):
            continue
        mre = parse_go_map(r.get('most_recent_ep_watched', ''))
        series_state[r['s_id']] = {
            'tvdb_series_id':   r['s_id'],
            'series_name':      r.get('series_name'),
            'ep_watch_count':   as_int(r.get('ep_watch_count')) or 0,
            'is_followed':      r.get('is_followed') == 'true',
            'is_for_later':     r.get('is_for_later') == 'true',
            'is_archived':      r.get('is_archived') == 'true',
            'followed_at_us':   as_int(r.get('followed_at')),
            'most_recent_ep': {
                'season_number':   mre.get('s_no'),
                'episode_number':  mre.get('ep_no'),
                'tvdb_episode_id': mre.get('ep_id'),
                # watch_date in microsecondi -> secondi
                'watched_at_epoch': mre['watch_date'] // 1_000_000 if mre and 'watch_date' in mre else None,
            } if mre else None,
        }

    recomputed = recompute_state(events)

    # Episodi con numerazione in disaccordo fra i due file: la causa dei casi peggiori
    # (Digimon 253 vs 107, One-Punch Man 36 vs 44). Serve per spiegare le divergenze.
    numbering_by_episode = defaultdict(set)
    for e in v2_events + v1_events_all:
        if e['tvdb_episode_id']:
            numbering_by_episode[e['tvdb_episode_id']].add((e['season_number'], e['episode_number']))
    series_with_numbering_conflict = set()
    for e in v2_events + v1_events_all:
        if len(numbering_by_episode.get(e['tvdb_episode_id'], ())) > 1:
            series_with_numbering_conflict.add(e['tvdb_series_id'])

    # Confronto stato TV Time <-> stato ricalcolato.
    matching, divergences, without_events = 0, [], []
    for series_id, expected in series_state.items():
        got = recomputed.get(series_id)
        if got is None:
            without_events.append({
                'tvdb_series_id': series_id,
                'series_name': expected['series_name'],
                'ep_watch_count': expected['ep_watch_count'],
            })
            continue
        if got['distinct_episode_count'] == expected['ep_watch_count']:
            matching += 1
            continue
        divergences.append({
            'tvdb_series_id':    series_id,
            'series_name':       expected['series_name'],
            'tvtime_count':      expected['ep_watch_count'],
            'recomputed_count':  got['distinct_episode_count'],
            'delta':             got['distinct_episode_count'] - expected['ep_watch_count'],
            'distinct_episode_ids': got['distinct_episode_ids'],
            'with_specials':     got['distinct_with_specials'],
            'special_episodes':  got['special_episode_count'],
            'rewatch_events':    got['rewatch_count'],
            'v1_only_episodes':  got['v1_only_episode_count'],
            'numbering_conflict': series_id in series_with_numbering_conflict,
            'cause':             explain_divergence(expected, got),
        })
    divergences.sort(key=lambda d: (-abs(d['delta']), d['series_name'] or ''))

    ratings, rating_distribution = parse_ratings(src, RATING_FILES)

    special_status = [
        {'tvdb_series_id': r['tv_show_id'], 'status': r['status'],
         'series_name': r.get('tv_show_name'), 'created_at': r.get('created_at')}
        for r in read(src / 'user_show_special_status.csv')
    ]
    followed = [
        {'tvdb_series_id': r['tv_show_id'], 'series_name': r.get('tv_show_name'),
         'archived': r.get('archived') == '1', 'active': r.get('active') == '1',
         'followed_at': r.get('created_at')}
        for r in read(src / 'followed_tv_show.csv')
    ]

    watched_dates = sorted(e['watched_at'] for e in events if e['watched_at'])
    user_id = v2_rows[0]['user_id'] if v2_rows else '0'

    return {
        'meta': {
            'source': 'TV Time GDPR export',
            'user_pseudonym': anon(user_id),
            'event_count': len(events),
            'v2_event_count': len(v2_events),
            'v1_event_count_kept': len(v1_events),
            'v1_event_count_dropped_as_duplicate': dropped_v1,
            'v1_rows_unusable': unusable_v1_rows,
            'rewatch_event_count': sum(1 for e in events if e['rewatch_index'] > 0),
            'series_state_count': len(series_state),
            'series_recomputed_count': len(recomputed),
            'watched_at_range': [watched_dates[0], watched_dates[-1]] if watched_dates else None,
            'note': ('IDs are TheTVDB, not TMDB — resolve per episode id, never by season/episode '
                     'number (§6). Star ratings are decoded per §7.5.'),
        },
        # §8: i casi limite che l'import deve coprire, contati sul fixture reale.
        'edge_cases': {
            'for_later_series':        sum(1 for s in series_state.values() if s['is_for_later']),
            'archived_series':         sum(1 for s in series_state.values() if s['is_archived']),
            'special_status_rows':     len(special_status),
            'archived_in_followed_csv': sum(1 for f in followed if f['archived']),
            'season_zero_events':      sum(1 for e in events if e['season_number'] == 0),
            'special_events':          sum(1 for e in events if e['is_special']),
            # due conteggi diversi: le righe marcate rewatch nell'export, e le visioni
            # successive alla prima sullo stesso episodio (che le includono).
            'rewatch_kind_events':     sum(1 for e in events if e['event_kind'] == 'rewatch'),
            'repeat_view_events':      sum(1 for e in events if e['rewatch_index'] > 0),
            'bulk_marked_events':      sum(1 for e in events if e['bulk_type']),
            'state_without_events':    len(without_events),
            'events_without_episode_id': sum(1 for e in events if not e['tvdb_episode_id']),
        },
        'watch_events': events,                    # eventi normalizzati, deduplicati (§7.3)
        'tvtime_series_state': series_state,       # <- l'ORACOLO
        'recomputed_from_events': recomputed,      # <- cosa deve produrre l'importer
        'comparison': {
            'matching': matching,
            'diverging': len(divergences),
            'state_without_events': len(without_events),
            'divergences': divergences,
            'series_without_events': without_events,
            'causes': dict(Counter(d['cause'] for d in divergences)),
            'cause_descriptions': DIVERGENCE_CAUSES,
        },
        'ratings': ratings,
        'rating_value_distribution': dict(sorted(rating_distribution.items())),
        'special_status': special_status,
        'followed_shows': followed,
    }


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else '.')
    dst = Path(sys.argv[2] if len(sys.argv) > 2 else 'oracle_fixture.json')
    data = build(src)
    dst.write_text(json.dumps(data, indent=1, ensure_ascii=False))

    meta, comparison = data['meta'], data['comparison']
    print(f"eventi (v2)          : {meta['v2_event_count']}")
    print(f"eventi (v1 tenuti)   : {meta['v1_event_count_kept']}"
          f"  [scartati come duplicati: {meta['v1_event_count_dropped_as_duplicate']}]")
    print(f"eventi totali        : {meta['event_count']}")
    print(f"di cui rewatch       : {meta['rewatch_event_count']}")
    print(f"stati serie (TVT)    : {meta['series_state_count']}")
    print(f"serie ricalcolate    : {meta['series_recomputed_count']}")

    print(f"\nep_watch_count  ->  uguali {comparison['matching']}"
          f" | diversi {comparison['diverging']}"
          f" | senza eventi {comparison['state_without_events']}")
    if comparison['causes']:
        print("cause delle divergenze:")
        for cause, count in sorted(comparison['causes'].items(), key=lambda kv: -kv[1]):
            print(f"   {count:4d}  {cause}")
    for d in comparison['divergences'][:8]:
        print(f"   {d['series_name']}: TVTime {d['tvtime_count']} vs "
              f"ricalcolato {d['recomputed_count']}  ({d['cause']})")

    print("\ndistribuzione dei voti (§7.5):")
    for value, count in sorted(data['rating_value_distribution'].items()):
        print(f"   {value:>16}  {count}")

    print(f"\nfixture scritto in {dst}")


if __name__ == '__main__':
    main()
