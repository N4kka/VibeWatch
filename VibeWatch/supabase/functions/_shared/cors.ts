// CORS per le edge function chiamate direttamente dal browser (web app, M0).
//
// **Perché un allowlist e non `*`.** Queste funzioni accettano la publishable key
// e alcune anche un JWT utente. Con `Access-Control-Allow-Origin: *` qualunque
// sito potrebbe far partire richieste dal browser di un utente loggato e
// consumare il suo budget AI o le sue quote. L'elenco è chiuso e corto.
//
// **Le app native non sono toccate.** Un client non-browser non manda `Origin`,
// e senza `Origin` qui non viene aggiunta nessuna intestazione: la risposta è
// identica a prima, byte per byte a meno del `Vary`.
//
// `Vary: Origin` c'è sempre, anche quando l'origine non è ammessa: senza, una
// cache intermedia potrebbe servire a un'origine la risposta preparata per
// un'altra.

const ALLOWED_ORIGINS = new Set([
  'https://vibewatchapp.com',
  'https://www.vibewatchapp.com',
  // Dev: `react-router dev` (Vite) e l'anteprima Pages/Wrangler.
  'http://localhost:5173',
  'http://localhost:8788',
])

// `x-client-info` e `x-supabase-api-version` li manda supabase-js da solo: se non
// sono elencati qui il preflight fallisce e la chiamata non parte nemmeno.
const ALLOWED_HEADERS = 'authorization, apikey, content-type, x-client-info, x-supabase-api-version'

export function corsHeaders(req: Request): Record<string, string> {
  const headers: Record<string, string> = { Vary: 'Origin' }
  const origin = req.headers.get('Origin')
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    headers['Access-Control-Allow-Origin'] = origin
    headers['Access-Control-Allow-Headers'] = ALLOWED_HEADERS
    headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    // Un giorno di preflight in cache: sono richieste che non fanno lavoro utile.
    headers['Access-Control-Max-Age'] = '86400'
  }
  return headers
}

/// Risponde al preflight. `null` quando la richiesta non è un OPTIONS, così il
/// chiamante prosegue.
///
/// Un'origine non ammessa riceve comunque 204, ma senza le intestazioni di
/// permesso: è il browser a fermare la richiesta vera. Rispondere con un errore
/// direbbe a un attaccante che l'endpoint esiste e come si chiama la difesa.
export function handleOptions(req: Request): Response | null {
  if (req.method !== 'OPTIONS') return null
  return new Response(null, { status: 204, headers: corsHeaders(req) })
}

/// Avvolge un handler `serve`: intercetta il preflight e aggiunge le intestazioni
/// CORS a ogni risposta, comprese quelle di errore.
///
/// È un wrapper e non una modifica a `jsonResponse` di proposito: `jsonResponse`
/// non ha la Request fra le mani, e cambiarne la firma avrebbe voluto dire
/// toccare ogni punto di chiamata di ogni funzione — con la certezza statistica
/// di dimenticarne uno, che si sarebbe visto solo come un errore CORS opaco nel
/// browser. Qui il punto da non dimenticare è uno per funzione.
export function withCors(
  handler: (req: Request) => Response | Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request): Promise<Response> => {
    const preflight = handleOptions(req)
    if (preflight) return preflight

    const response = await handler(req)
    const headers = new Headers(response.headers)
    for (const [key, value] of Object.entries(corsHeaders(req))) {
      headers.set(key, value)
    }
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    })
  }
}
