#!/bin/bash
# Upload dei dSYM a PostHog per la simbolicazione dei crash ($exception).
#
# Due modi d'uso:
#
# 1) Run Script phase in Xcode (consigliato, automatico a ogni archive Release):
#    aggiungere una Build Phase "Run Script" al target VibeWatchApp con:
#        "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/posthog-ios/build-tools/upload-symbols.sh"
#    (lo script ufficiale dell'SDK: salta da solo le build non-Release; richiede
#    ENABLE_USER_SCRIPT_SANDBOXING = NO e Debug Information Format = DWARF with dSYM File)
#
# 2) Manuale, su un .xcarchive già prodotto — questo script:
#        ./VibeWatchTools/upload-dsyms.sh [path/allo/.xcarchive]
#    Senza argomenti prende l'archivio più recente in ~/Library/Developer/Xcode/Archives.
#
# Prerequisiti:
#   - posthog-cli >= 0.10.0:  npm install -g @posthog/cli@latest
#   - autenticazione: `posthog-cli login`, oppure variabili d'ambiente:
#       POSTHOG_CLI_HOST=https://eu.posthog.com
#       POSTHOG_CLI_PROJECT_ID=109767
#       POSTHOG_CLI_API_KEY=<personal API key con scope "error tracking write" + "organization read">
#
# Riferimento: https://posthog.com/docs/error-tracking/upload-source-maps/ios

set -euo pipefail

ARCHIVE_PATH="${1:-}"

if [[ -z "$ARCHIVE_PATH" ]]; then
    ARCHIVE_PATH=$(find ~/Library/Developer/Xcode/Archives -name "*.xcarchive" -maxdepth 2 -print0 2>/dev/null \
        | xargs -0 ls -dt 2>/dev/null | head -1 || true)
    if [[ -z "$ARCHIVE_PATH" ]]; then
        echo "Nessun .xcarchive trovato. Passa il path esplicitamente:" >&2
        echo "  $0 path/allo/App.xcarchive" >&2
        exit 1
    fi
    echo "Archivio più recente: $ARCHIVE_PATH"
fi

DSYM_DIR="$ARCHIVE_PATH/dSYMs"
if [[ ! -d "$DSYM_DIR" ]]; then
    echo "Cartella dSYMs non trovata in $ARCHIVE_PATH." >&2
    echo "Verifica in Build Settings: Debug Information Format = DWARF with dSYM File (Release)." >&2
    exit 1
fi

if ! command -v posthog-cli >/dev/null 2>&1; then
    echo "posthog-cli non trovato (npm install -g @posthog/cli@latest)." >&2
    exit 1
fi

export POSTHOG_CLI_HOST="${POSTHOG_CLI_HOST:-https://eu.posthog.com}"

echo "Upload dSYM da: $DSYM_DIR"
posthog-cli dsym upload --directory "$DSYM_DIR" --main-dsym "VibeWatchApp.app.dSYM"
echo "Fatto. I prossimi crash arriveranno simbolicati in Error tracking."
