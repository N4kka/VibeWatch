import { assertEquals } from 'jsr:@std/assert@1'
import { buildRows, FILE_V1, FILE_V2, RATING_FILES, readCsvEntries } from './archive.ts'

/**
 * Collaudo contro l'export TV Time vero.
 *
 * Non è nel repo e non deve esserci: è l'archivio GDPR di una persona reale. Il percorso arriva da
 * `TVTIME_ZIP`, e senza quella variabile il test si salta invece di fallire.
 *
 *   TVTIME_ZIP=/percorso/gdpr-data.zip deno test --allow-read --allow-env
 *
 * Copre esattamente ciò che i test di `parsing.ts` non possono coprire: che lo ZIP si apra, che i
 * file si chiamino come §7.1 dice, e che il CSV non abbia sorprese di quoting. I numeri attesi
 * vengono dall'oracolo, che ha letto lo stesso archivio con `build_oracle.py`.
 */
const zipPath = Deno.env.get('TVTIME_ZIP')

Deno.test({
  name: 'archivio reale: lo ZIP si apre e produce gli stessi numeri dell oracolo',
  ignore: !zipPath,
  fn: async () => {
    const bytes = await Deno.readFile(zipPath!)
    const files = await readCsvEntries(new Blob([bytes]), [FILE_V2, FILE_V1, ...RATING_FILES])

    // 1. I file di §7.1 esistono e si chiamano davvero così.
    assertEquals(files.has(FILE_V2), true, `manca ${FILE_V2}`)

    const { events, ratings, unusableV1, droppedV1 } = buildRows(files)

    console.log(JSON.stringify({
      file_trovati: [...files.keys()],
      eventi: events.length,
      voti: ratings.length,
      v1_inutilizzabili: unusableV1,
      v1_scartati_come_duplicati: droppedV1,
    }, null, 2))

    // 2. Il conteggio dell'oracolo, sullo stesso archivio.
    assertEquals(events.length, 21_344, 'eventi diversi da quelli che l oracolo ha contato')

    // 3. Ogni evento ha una chiave di dedup: senza, il reimport duplica (criterio 2 di §13).
    const senzaChiave = events.filter((e) => !e.dedup_key).length
    assertEquals(senzaChiave, 0, 'eventi senza dedup_key')

    // 4. Le chiavi sono uniche. È l'invariante che rende l'import idempotente, e l'unico modo per
    //    accorgersi che l'ordinamento è instabile su dati veri.
    assertEquals(new Set(events.map((e) => e.dedup_key)).size, events.length, 'dedup_key duplicate')

    // 5. Il quoting del CSV: se fosse rotto, i campi slitterebbero di colonna e le date sarebbero
    //    vuote o assurde. Qui si guarda che siano tutte date plausibili.
    const dateStrane = events.filter((e) => !/^\d{4}-\d{2}-\d{2}/.test(e.watched_at)).length
    assertEquals(dateStrane, 0, 'date non riconoscibili: probabile disallineamento di colonne')
  },
})
