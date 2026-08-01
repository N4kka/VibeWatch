# Universal links (SPEC v3 §9.4) — cosa c'è e cosa aspetta il dominio

> Stato al 2026-08-01: la parte client è fatta; il dominio **non è ancora deciso**, quindi
> `vibewatch.app` è un segnaposto ovunque compaia. La verifica end-to-end sul dispositivo
> si può fare solo quando un dominio vero servirà il file qui accanto.

## Le rotte

| Rotta | Destinazione nell'app |
|---|---|
| `/@{username}` | `PublicProfileView(username:)`, presentata come sheet da `MainTabView` |
| `/film/{id}` | il dettaglio film, stessa strada delle notifiche push (`deepLinkTarget`) |

Il riconoscimento sta tutto in `UniversalLinks.route(for:)` (`VibeWatchApp/Core/Utilities/`):
funzione pura, coperta da `UniversalLinksTests`. Un URL che non è una di queste due rotte
**cade** — nessuna destinazione di ripiego.

## Quando il dominio esiste: la checklist

1. **Cambiare `UniversalLinks.host`** in `UniversalLinks.swift` — è l'unico punto nel codice.
2. **Cambiare la voce `applinks:` nei due entitlement** (`VibeWatchApp.entitlements` e
   `VibeWatchAppRelease.entitlements`). Il test `testEntitlementsCombacianoConHost` fallisce
   finché i tre valori non combaciano, quindi il passo non si può dimenticare a metà.
3. **Servire il file `apple-app-site-association`** (quello in questa cartella) a:
   `https://{dominio}/.well-known/apple-app-site-association`
   - HTTPS con certificato valido, **nessun redirect**;
   - `Content-Type: application/json`;
   - il nome del file è senza estensione, così com'è qui;
   - se `www.{dominio}` e `{dominio}` rispondono entrambi, entrambi devono servirlo, e
     l'entitlement deve elencare **entrambi** gli host (gli `applinks:` distinguono i sottodomini).
4. **Il sito deve anche rispondere alle due rotte** con una pagina vera (§9.4: la pagina del
   profilo/film con il rimando all'app): l'universal link apre l'app solo se installata, il
   resto del mondo vede la pagina.

## Come si collauda sul dispositivo

- Apple **non** rilegge l'AASA a ogni avvio: la scarica via CDN all'installazione dell'app.
  Per iterare senza aspettare la CDN: entitlement `applinks:{dominio}?mode=developer` +
  la modalità sviluppatore sul dispositivo (Impostazioni → Sviluppatore → Associated Domains
  Development). Togliere `?mode=developer` prima del rilascio.
- Diagnosi: `curl -i https://{dominio}/.well-known/apple-app-site-association` e, sul Mac,
  la CDN di Apple: `curl https://app-site-association.cdn-apple.com/a/v1/{dominio}`.
- Il criterio pratico del blocco 10 (lo stato §12): un link `/@{username}` toccato in Note o
  Messaggi apre il profilo giusto **nell'app**. Un tap dalla barra di Safari non conta: da lì
  Apple apre di proposito il sito, non l'app.

## Perché il file sta in `docs/` e non in un sito

Il sito "arriva subito dopo" (§9.4) e non vive in questo repo. Il file è qui perché è
**pronto e già giusto** — elenca percorsi, non host, quindi non dipende dal dominio — e
perché la coppia appID/percorsi deve evolvere insieme al client, non insieme al sito.
