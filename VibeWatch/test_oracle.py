#!/usr/bin/env python3
"""
Harness dell'oracolo (SPEC v3 §8, blocco 1 di §12).

Due gruppi di test:

1. Sul FIXTURE (`oracle_fixture.json`, generato da `build_oracle.py` sull'export reale):
   blocca la baseline che l'import dovra' riprodurre — 399 serie che combaciano, 31 che
   divergono, 37 con stato ma senza eventi — e verifica le invarianti su cui si appoggiano
   i criteri di accettazione: dedup v1/v2, idempotenza delle dedup_key, speciali fuori dal
   progresso, decodifica dei voti.

2. Sulle FUNZIONI di `build_oracle.py`, con righe sintetiche: sono le regole che il
   parser dell'import dovra' replicare, e vanno testate senza dipendere dall'export di
   una persona reale.

Uso:  python3 test_oracle.py          (oppure: python3 -m unittest test_oracle -v)
"""

import json
import unittest
from collections import Counter, defaultdict
from pathlib import Path

import build_oracle

FIXTURE = Path(__file__).with_name('oracle_fixture.json')

# Baseline misurata sull'export reale in repo. Se cambia, o e' cambiato il fixture o e'
# cambiata una regola: in entrambi i casi va aggiornata a mano, mai in automatico.
EXPECTED_MATCHING = 399
EXPECTED_DIVERGING = 31
EXPECTED_WITHOUT_EVENTS = 37

# §8: le divergenze senza spiegazione meccanica sono la lista di lavoro prima del rilascio.
UNRESOLVED_CAUSES = {'needs_manual_review', 'episode_id_collision_partial'}
MAX_UNRESOLVED = 4


def load_fixture():
    with FIXTURE.open(encoding='utf-8') as fh:
        return json.load(fh)


class FixtureBaselineTests(unittest.TestCase):
    """Cio' che l'import dovra' riprodurre, congelato."""

    @classmethod
    def setUpClass(cls):
        cls.data = load_fixture()

    def test_comparison_baseline_is_unchanged(self):
        comparison = self.data['comparison']
        self.assertEqual(comparison['matching'], EXPECTED_MATCHING)
        self.assertEqual(comparison['diverging'], EXPECTED_DIVERGING)
        self.assertEqual(comparison['state_without_events'], EXPECTED_WITHOUT_EVENTS)
        self.assertEqual(
            comparison['matching'] + comparison['diverging'] + comparison['state_without_events'],
            self.data['meta']['series_state_count'],
            'ogni serie con stato TV Time deve finire in una delle tre categorie',
        )

    def test_every_divergence_has_a_documented_cause(self):
        """§8: una divergenza accettata va documentata con la ragione, non ignorata."""
        descriptions = self.data['comparison']['cause_descriptions']
        for divergence in self.data['comparison']['divergences']:
            self.assertIn(divergence['cause'], descriptions,
                          f"{divergence['series_name']}: causa senza descrizione")
            self.assertNotEqual(divergence['delta'], 0)

    def test_unresolved_divergences_stay_within_the_known_list(self):
        unresolved = [d for d in self.data['comparison']['divergences']
                      if d['cause'] in UNRESOLVED_CAUSES]
        self.assertLessEqual(
            len(unresolved), MAX_UNRESOLVED,
            'nuove divergenze senza spiegazione: '
            + ', '.join(f"{d['series_name']} ({d['tvtime_count']} vs {d['recomputed_count']})"
                        for d in unresolved),
        )


class FixtureInvariantTests(unittest.TestCase):
    """Invarianti che i criteri di accettazione di §13 danno per scontate."""

    @classmethod
    def setUpClass(cls):
        cls.data = load_fixture()
        cls.events = cls.data['watch_events']

    def test_v1_events_never_duplicate_a_v2_episode(self):
        """§7.3: v2 vince; da v1 restano solo gli episodi che v2 non ha."""
        v2_ids = {e['tvdb_episode_id'] for e in self.events if e['origin'] == 'v2'}
        overlapping = [e for e in self.events
                       if e['origin'] == 'v1' and e['tvdb_episode_id'] in v2_ids]
        self.assertEqual(overlapping, [], 'un evento v1 duplica un episodio gia presente in v2')

    def test_dedup_keys_are_unique(self):
        """Criterio 2 di §13: reimportare lo stesso ZIP non deve duplicare nessun evento."""
        keys = [e['dedup_key'] for e in self.events if e['dedup_key']]
        duplicates = [key for key, count in Counter(keys).items() if count > 1]
        self.assertEqual(duplicates, [], f'dedup_key duplicate: {duplicates[:5]}')

    def test_rewatch_indexes_are_contiguous_and_chronological(self):
        """§3.2: 0 = prima visione, poi 1, 2, ... in ordine di visione sullo stesso episodio."""
        by_episode = defaultdict(list)
        for event in self.events:
            if event['tvdb_episode_id']:
                by_episode[event['tvdb_episode_id']].append(event)

        for episode_id, group in by_episode.items():
            indexes = sorted(e['rewatch_index'] for e in group)
            self.assertEqual(indexes, list(range(len(group))),
                             f'rewatch_index non contigui per episodio {episode_id}')
            chronological = sorted(group, key=lambda e: e['rewatch_index'])
            timestamps = [e['watched_at'] for e in chronological]
            self.assertEqual(timestamps, sorted(timestamps),
                             f'rewatch_index non in ordine cronologico per episodio {episode_id}')

    def test_specials_stay_out_of_progress_but_stay_tracked(self):
        """§1.3: uno speciale si marca, non si filtra."""
        specials = [e for e in self.events if e['is_special']]
        self.assertGreater(len(specials), 0, 'il fixture deve contenere speciali')

        for series_id, state in self.data['recomputed_from_events'].items():
            self.assertLessEqual(state['distinct_episode_count'], state['distinct_with_specials'])
            self.assertEqual(
                state['distinct_with_specials'],
                state['distinct_episode_count'] + state['special_episode_count'],
                f'serie {series_id}: gli speciali non tornano',
            )

    def test_bulk_marked_events_are_flagged_as_inferred(self):
        """§3.2: il timestamp di un 'segna stagione' non e' l'ora di visione."""
        for event in self.events:
            expected = 'inferred' if event['bulk_type'] else 'exact'
            self.assertEqual(event['watched_at_precision'], expected)

    def test_every_event_carries_what_the_importer_needs(self):
        required = ('tvdb_series_id', 'tvdb_episode_id', 'season_number', 'episode_number',
                    'watched_at', 'is_special', 'rewatch_index', 'dedup_key', 'origin',
                    'event_kind', 'watched_at_precision')
        for event in self.events[:2000]:      # campione: la forma e' uniforme per costruzione
            for field in required:
                self.assertIn(field, event)
            self.assertTrue(event['tvdb_series_id'])
            self.assertTrue(event['watched_at'])

    def test_edge_cases_from_the_spec_are_present(self):
        """§8: i casi limite che l'import deve coprire esistono davvero nel fixture."""
        edge = self.data['edge_cases']
        self.assertGreater(edge['rewatch_kind_events'], 0)
        self.assertGreater(edge['repeat_view_events'], 0)
        self.assertGreater(edge['season_zero_events'], 0)
        self.assertGreater(edge['for_later_series'], 0)
        self.assertGreater(edge['archived_series'], 0)
        self.assertGreater(edge['state_without_events'], 0)


class FixtureRatingTests(unittest.TestCase):
    """§7.5: stelle e reaction sono due dimensioni diverse mescolate negli stessi file."""

    @classmethod
    def setUpClass(cls):
        cls.ratings = load_fixture()['ratings']

    def test_stars_convert_to_half_star_scale(self):
        stars = [r for r in self.ratings if r['kind'] == 'star']
        self.assertGreater(len(stars), 0)
        for rating in stars:
            self.assertLessEqual(rating['raw_value'], build_oracle.STAR_MAX)
            self.assertEqual(rating['star_rating'], rating['raw_value'] * 2)
            self.assertTrue(1 <= rating['star_rating'] <= 10, 'user_ratings.rating e 1-10')
            self.assertEqual(rating['tvtime_star_raw'], rating['raw_value'],
                             'il valore grezzo va conservato per rifare la conversione')
            self.assertIsNone(rating['reaction_id'])

    def test_reactions_are_kept_raw(self):
        reactions = [r for r in self.ratings if r['kind'] == 'reaction']
        self.assertGreater(len(reactions), 0)
        for rating in reactions:
            self.assertGreaterEqual(rating['raw_value'], build_oracle.REACTION_MIN)
            self.assertIsNone(rating['star_rating'], 'una reaction non e un voto in stelle')
            self.assertEqual(rating['reaction_id'], rating['raw_value'])

    def test_no_value_lands_in_the_undefined_band(self):
        """6..12 non e' mai stato osservato: se comparisse, la regola di §7.5 va rivista."""
        band = [r for r in self.ratings
                if r['raw_value'] is not None
                and build_oracle.STAR_MAX < r['raw_value'] < build_oracle.REACTION_MIN]
        self.assertEqual(band, [])


class ParserRuleTests(unittest.TestCase):
    """Le regole del parser, su righe sintetiche: nessuna dipendenza dall'export reale."""

    def test_v2_wins_over_v1_for_the_same_episode(self):
        v2 = build_oracle.parse_v2_events([{
            'key': 'watch-episode-abc-def', 's_id': '1', 'ep_id': '100',
            'season_number': '2', 'episode_number': '5', 'created_at': '2025-01-01 10:00:00',
            'runtime': '1440', 'is_special': 'false', 'series_name': 'Show', 'bulk_type': '',
        }])
        v1, _ = build_oracle.parse_v1_events([
            {   # stesso episodio, numerazione assoluta: va scartato
                'type': 'watch', 'entity_type': 'episode', 'series_id': '1', 'episode_id': '100',
                'season_number': '1', 'episode_number': '17', 'created_at': '2024-01-01 10:00:00',
                'runtime': '1440', 'series_name': 'Show', 'bulk_type': '',
            },
            {   # episodio che v2 non ha: va tenuto
                'type': 'watch', 'entity_type': 'episode', 'series_id': '1', 'episode_id': '999',
                'season_number': '1', 'episode_number': '1', 'created_at': '2024-01-02 10:00:00',
                'runtime': '1440', 'series_name': 'Show', 'bulk_type': '',
            },
        ])

        kept, dropped, _ = build_oracle.dedup_v1_into_v2(v2, v1)
        self.assertEqual(dropped, 1)
        self.assertEqual([e['tvdb_episode_id'] for e in kept], ['999'])

    def test_dedup_never_merges_by_season_and_episode(self):
        """§7.3: fondere per (stagione, episodio) inventerebbe episodi (One-Punch Man 36 vs 44)."""
        v2 = build_oracle.parse_v2_events([{
            'key': 'watch-episode-a', 's_id': '1', 'ep_id': '100', 'season_number': '1',
            'episode_number': '1', 'created_at': '2025-01-01 10:00:00', 'runtime': '1440',
            'is_special': 'false', 'series_name': 'Show', 'bulk_type': '',
        }])
        v1, _ = build_oracle.parse_v1_events([{
            'type': 'watch', 'entity_type': 'episode', 'series_id': '1', 'episode_id': '200',
            'season_number': '1', 'episode_number': '1', 'created_at': '2024-01-01 10:00:00',
            'runtime': '1440', 'series_name': 'Show', 'bulk_type': '',
        }])
        kept, dropped, _ = build_oracle.dedup_v1_into_v2(v2, v1)
        self.assertEqual(dropped, 0, 'stessa coppia S/E ma id diverso: non e un duplicato')
        self.assertEqual(len(kept), 1)

    def test_unusable_v1_rows_are_skipped_and_counted(self):
        """v1 contiene righe rewatch senza id: non importabili, ma da dichiarare nel report (§7.4)."""
        events, unusable = build_oracle.parse_v1_events([
            {'type': 'rewatch', 'entity_type': 'episode', 'series_id': '', 'episode_id': '',
             'season_number': '', 'episode_number': '', 'created_at': '2024-01-01 10:00:00',
             'runtime': '', 'series_name': '', 'bulk_type': ''},
            {'type': 'watch', 'entity_type': 'episode', 'series_id': '1', 'episode_id': '100',
             'season_number': '1', 'episode_number': '1', 'created_at': '2024-01-02 10:00:00',
             'runtime': '1440', 'series_name': 'Show', 'bulk_type': ''},
        ])
        self.assertEqual(unusable, 1)
        self.assertEqual([e['tvdb_episode_id'] for e in events], ['100'])

    def test_rewatch_index_and_dedup_key(self):
        events = build_oracle.parse_v2_events([
            {'key': 'rewatch-episode-a', 's_id': '1', 'ep_id': '100', 'season_number': '1',
             'episode_number': '1', 'created_at': '2025-06-01 10:00:00', 'runtime': '1440',
             'is_special': 'false', 'series_name': 'Show', 'bulk_type': ''},
            {'key': 'watch-episode-a', 's_id': '1', 'ep_id': '100', 'season_number': '1',
             'episode_number': '1', 'created_at': '2024-01-01 10:00:00', 'runtime': '1440',
             'is_special': 'false', 'series_name': 'Show', 'bulk_type': ''},
        ])
        build_oracle.assign_rewatch_index(events)

        by_time = sorted(events, key=lambda e: e['watched_at'])
        self.assertEqual([e['rewatch_index'] for e in by_time], [0, 1])
        self.assertEqual([e['dedup_key'] for e in by_time],
                         ['tvtime:100:0', 'tvtime:100:1'])

    def test_bulk_season_is_inferred_precision(self):
        events = build_oracle.parse_v2_events([{
            'key': 'watch-episode-a', 's_id': '1', 'ep_id': '100', 'season_number': '1',
            'episode_number': '1', 'created_at': '2025-01-01 10:00:00', 'runtime': '1440',
            'is_special': 'false', 'series_name': 'Show', 'bulk_type': 'season',
        }])
        self.assertEqual(events[0]['watched_at_precision'], 'inferred')
        self.assertEqual(events[0]['bulk_type'], 'season')

    def test_specials_do_not_enter_the_recomputed_progress(self):
        events = build_oracle.parse_v2_events([
            {'key': 'watch-episode-a', 's_id': '1', 'ep_id': '100', 'season_number': '1',
             'episode_number': '1', 'created_at': '2025-01-01 10:00:00', 'runtime': '1440',
             'is_special': 'false', 'series_name': 'Show', 'bulk_type': ''},
            {'key': 'watch-episode-b', 's_id': '1', 'ep_id': '101', 'season_number': '0',
             'episode_number': '1', 'created_at': '2025-01-02 10:00:00', 'runtime': '1440',
             'is_special': 'true', 'series_name': 'Show', 'bulk_type': ''},
        ])
        build_oracle.assign_rewatch_index(events)
        state = build_oracle.recompute_state(events)['1']

        self.assertEqual(state['distinct_episode_count'], 1, 'lo speciale non entra nel progresso')
        self.assertEqual(state['special_episode_count'], 1, 'ma resta tracciato')
        self.assertEqual(state['last_season'], 1, "l'ultimo visto non puo essere uno speciale")

    def test_explain_divergence_distinguishes_ids_from_numbers(self):
        """Il caso Digimon: 253 id TVDB su 107 coppie (stagione, episodio)."""
        cause = build_oracle.explain_divergence(
            {'ep_watch_count': 253},
            {'distinct_episode_count': 107, 'distinct_with_specials': 107,
             'distinct_episode_ids': 253, 'special_episode_count': 0, 'rewatch_count': 0},
        )
        self.assertEqual(cause, 'tvtime_counted_episode_ids')

    def test_explain_divergence_recognises_specials(self):
        cause = build_oracle.explain_divergence(
            {'ep_watch_count': 39},
            {'distinct_episode_count': 33, 'distinct_with_specials': 39,
             'distinct_episode_ids': 39, 'special_episode_count': 6, 'rewatch_count': 0},
        )
        self.assertEqual(cause, 'specials_counted_by_tvtime')

    def test_explain_divergence_admits_when_it_cannot_explain(self):
        cause = build_oracle.explain_divergence(
            {'ep_watch_count': 2},
            {'distinct_episode_count': 8, 'distinct_with_specials': 8,
             'distinct_episode_ids': 8, 'special_episode_count': 0, 'rewatch_count': 0},
        )
        self.assertEqual(cause, 'needs_manual_review')


if __name__ == '__main__':
    unittest.main(verbosity=2)
