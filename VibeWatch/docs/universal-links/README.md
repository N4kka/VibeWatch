# Universal links (SPEC v3 §9.4) — cosa c'è e cosa aspetta il sito

> Stato al 2026-08-01: la parte client è fatta e il dominio è deciso — **`vibewatchapp.com`**,
> già dentro `UniversalLinks.host` e nei due entitlement (apex e www). La verifica end-to-end
> sul dispositivo si può fare solo quando il dominio servirà il file qui accanto.

## Le rotte

| Rotta | Destinazione nell'app |
|---|---|
| `/@{username}` | `PublicProfileView(username:)`, presentata come sheet da `MainTabView` |
| `/film/{id}` | il dettaglio film, stessa strada delle notifiche push (`deepLinkTarget`) |

Il riconoscimento sta tutto in `UniversalLinks.route(for:)` (`VibeWatchApp/Core/Utilities/`):
funzione pura, coperta da `UniversalLinksTests`. Un URL che non è una di queste due rotte
**cade** — nessuna destinazione di ripiego.

## La checklist — dove siamo

1. ~~**Cambiare `UniversalLinks.host`**~~ — fatto: `vibewatchapp.com` (2026-08-01).
2. ~~**Le voci `applinks:` nei due entitlement**~~ — fatte, apex **e** www (gli `applinks:`
   distinguono i sottodomini). Il test `testEntitlementsCombacianoConHost` pretende entrambe
   le voci in entrambi i file: se in futuro il dominio cambiasse ancora, fallisce lui prima
   che fallisca un link.
3. **Servire il file `apple-app-site-association`** (quello in questa cartella) a:
   `https://vibewatchapp.com/.well-known/apple-app-site-association`
   - HTTPS con certificato valido, **nessun redirect**;
   - `Content-Type: application/json`;
   - il nome del file è senza estensione, così com'è qui;
   - anche su `https://www.vibewatchapp.com/...`, perché l'entitlement dichiara entrambi:
     un redirect www → apex qui **non vale** — Apple vuole il file, non un 301.
4. **Il sito deve anche rispondere alle due rotte** con una pagina vera (§9.4: la pagina del
   profilo/film con il rimando all'app): l'universal link apre l'app solo se installata, il
   resto del mondo vede la pagina.

## Come si collauda sul dispositivo

- Apple **non** rilegge l'AASA a ogni avvio: la scarica via CDN all'installazione dell'app.
  Per iterare senza aspettare la CDN: entitlement `applinks:vibewatchapp.com?mode=developer` +
  la modalità sviluppatore sul dispositivo (Impostazioni → Sviluppatore → Associated Domains
  Development). Togliere `?mode=developer` prima del rilascio.
- Diagnosi: `curl -i https://vibewatchapp.com/.well-known/apple-app-site-association` e, sul Mac,
  la CDN di Apple: `curl https://app-site-association.cdn-apple.com/a/v1/vibewatchapp.com`.
- Il criterio pratico del blocco 10 (lo stato §12): un link `/@{username}` toccato in Note o
  Messaggi apre il profilo giusto **nell'app**. Un tap dalla barra di Safari non conta: da lì
  Apple apre di proposito il sito, non l'app.

## Perché il file sta in `docs/` e non in un sito

Il sito "arriva subito dopo" (§9.4) e non vive in questo repo. Il file è qui perché è
**pronto e già giusto** — elenca percorsi, non host, quindi non dipende dal dominio — e
perché la coppia appID/percorsi deve evolvere insieme al client, non insieme al sito.
