#!/usr/bin/env bash
# Esegue i test SQL su un PostgreSQL usa-e-getta.
#
# Non tocca nessun database esistente e non lascia servizi in giro: crea un cluster in una
# directory temporanea, lo ascolta solo su 127.0.0.1, applica harness.sql e tutte le migration in
# ordine, esegue i test e poi butta via tutto.
#
# Uso:   supabase/tests/run.sh
# Serve: initdb/pg_ctl/psql nel PATH (brew install postgresql@18).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS="$HERE/../supabase/migrations"
PORT="${PGTEST_PORT:-55433}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vwpg.XXXXXX")"
PGDATA_DIR="$WORK_DIR/data"

cleanup() {
  pg_ctl -D "$PGDATA_DIR" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for binary in initdb pg_ctl psql; do
  command -v "$binary" >/dev/null 2>&1 || { echo "manca $binary nel PATH"; exit 127; }
done

echo "→ cluster temporaneo in $PGDATA_DIR (porta $PORT)"
initdb -D "$PGDATA_DIR" -U postgres --no-locale -E UTF8 >"$WORK_DIR/initdb.log" 2>&1 \
  || { cat "$WORK_DIR/initdb.log"; exit 1; }

# TCP e non socket unix: il path del socket in una temp directory supera spesso i 103 byte
# ammessi da macOS, e il server rifiuta di partire.
pg_ctl -D "$PGDATA_DIR" -l "$WORK_DIR/server.log" \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=" \
  -w start >/dev/null

run() { psql -h 127.0.0.1 -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -X -q "$@"; }

echo "→ harness"
run -f "$HERE/harness.sql" >/dev/null

# Due passate, di proposito: una migration va potuta riapplicare senza rompersi, ed e' il modo
# in cui viene riapplicata quando qualcuno la lancia due volte sul progetto sbagliato e poi su
# quello giusto.
for pass in 1 2; do
echo "→ migration (passata $pass)"
for file in "$MIGRATIONS"/*.sql; do
  # Le migration precedenti a SPEC v3 presuppongono lo schema di produzione, che qui non c'e':
  # l'harness ricrea solo cio' che serve ai test del tracking e dell'import. Si elencano per nome
  # invece di allargare il glob: `20260731010000_apply_mutations_tracking` riscrive una funzione
  # che tocca meta' dello schema di produzione e qui non avrebbe le tabelle su cui appoggiarsi.
  case "$(basename "$file")" in
    202607300*) ;;
    20260731120000_create_import_jobs.sql) ;;
    20260731140000_import_report.sql) ;;
    20260731180000_tracking_views_with_catalog.sql) ;;
    20260801000000_legacy_seen_shows_expansion.sql) ;;
    20260801100000_usernames_and_public_profiles.sql) ;;
    20260801110000_backfill_usernames.sql) ;;
    20260801120000_set_username.sql) ;;
    20260801130000_user_follows_and_search.sql) ;;
    20260801150000_get_public_profile.sql) ;;
    20260801170000_user_favorites_and_ratings.sql) ;;
    *) continue ;;
  esac
  [ "$pass" = 1 ] && echo "   $(basename "$file")"
  run -f "$file" >/dev/null
done
done

echo "→ test: tracking"
run -f "$HERE/tracking_test.sql"

echo "→ test: sociale"
run -f "$HERE/social_test.sql"

echo "→ test: favorites e rating"
run -f "$HERE/favorites_ratings_test.sql"
