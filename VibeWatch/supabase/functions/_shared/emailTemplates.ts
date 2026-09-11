// The HTML VibeWatch actually sends. One layout, three uses.
//
// The dispatcher's fallback mail used to be `<p>${body}</p><p>Log in to VibeWatch to see more.</p>`
// — which is what an unbranded, unlocalized, unsubscribable message looks like in an inbox that
// also holds JustWatch's. Everything here is table-based and inline-styled because that is the
// only layout email clients agree on, carries a plain-text alternative (Gmail's spam heuristics
// notice its absence), and states in its own footer why it arrived and where to switch it off.
//
// Copy comes from _shared/i18n.ts in the recipient's language; only the poster URLs and the
// title strings are data.

import { t } from './i18n.ts'

// Dal cutover (2026-08-16) e' questo il sito, non piu' la vecchia landing su
// vibe-watch.com: il bottone dice "apri VibeWatch" e adesso c'e' un VibeWatch da
// aprire. Stessa origine che il dispatcher scrive in `webpush.fcm_options.link`.
const APP_LINK = 'https://vibewatchapp.com'
const POSTER_BASE = 'https://image.tmdb.org/t/p/w154'

export type EmailItem = {
  title: string
  subtitle: string
  posterPath?: string | null
}

export type EmailSection = {
  heading: string
  items: EmailItem[]
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function itemRow(item: EmailItem): string {
  const poster = item.posterPath
    ? `<td width="56" valign="top" style="padding:0 12px 0 0;">
         <img src="${POSTER_BASE}${escapeHtml(item.posterPath)}" width="56" alt=""
              style="display:block;border-radius:6px;width:56px;height:auto;" />
       </td>`
    : ''

  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 14px 0;">
      <tr>
        ${poster}
        <td valign="top" style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
          <div style="font-size:15px;font-weight:600;color:#101014;line-height:1.35;">${escapeHtml(item.title)}</div>
          <div style="font-size:13px;color:#6b6b76;line-height:1.45;padding-top:2px;">${escapeHtml(item.subtitle)}</div>
        </td>
      </tr>
    </table>`
}

function sectionBlock(section: EmailSection): string {
  if (section.items.length === 0) return ''
  return `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;
                font-size:12px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;
                color:#8a8a95;padding:22px 0 10px 0;">${escapeHtml(section.heading)}</div>
    ${section.items.map(itemRow).join('')}`
}

export type EmailDocument = { subject: string; html: string; text: string }

function layout(
  language: string | null | undefined,
  options: { subject: string; heading: string; intro?: string; sections: EmailSection[] }
): EmailDocument {
  const body = options.sections.map(sectionBlock).join('')

  const html = `<!doctype html>
<html><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width,initial-scale=1" />
<title>${escapeHtml(options.subject)}</title></head>
<body style="margin:0;padding:0;background:#f5f5f7;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f7;padding:24px 12px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0"
             style="max-width:520px;background:#ffffff;border-radius:14px;padding:28px 24px;">
        <tr><td style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
          <div style="font-size:13px;font-weight:700;letter-spacing:0.14em;text-transform:uppercase;color:#7c4dff;">VibeWatch</div>
          <div style="font-size:22px;font-weight:700;color:#101014;padding:10px 0 0 0;line-height:1.25;">${escapeHtml(options.heading)}</div>
          ${options.intro ? `<div style="font-size:14px;color:#6b6b76;padding:8px 0 0 0;line-height:1.5;">${escapeHtml(options.intro)}</div>` : ''}
          ${body}
          <div style="padding:26px 0 0 0;">
            <a href="${APP_LINK}" style="display:inline-block;background:#7c4dff;color:#ffffff;text-decoration:none;
               font-size:14px;font-weight:600;padding:11px 22px;border-radius:999px;">${escapeHtml(t(language, 'email.cta'))}</a>
          </div>
          <div style="font-size:11px;color:#9a9aa4;padding:24px 0 0 0;line-height:1.5;">${escapeHtml(t(language, 'email.footer'))}</div>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`

  const text = [
    options.heading,
    options.intro ?? '',
    ...options.sections
      .filter((section) => section.items.length > 0)
      .flatMap((section) => [
        '',
        section.heading.toUpperCase(),
        ...section.items.map((item) => `- ${item.title} — ${item.subtitle}`),
      ]),
    '',
    `${t(language, 'email.cta')}: ${APP_LINK}`,
    '',
    t(language, 'email.footer'),
  ].join('\n')

  return { subject: options.subject, html, text }
}

/** Daily "what happened to the titles you saved". Sections are already grouped by the caller. */
export function renderDigestEmail(language: string | null | undefined, sections: EmailSection[]): EmailDocument {
  return layout(language, {
    subject: t(language, 'email.digest.subject'),
    heading: t(language, 'email.digest.heading'),
    intro: t(language, 'email.digest.intro'),
    sections,
  })
}

/** Sunday recap: what is coming in the next seven days, and what happened in the last seven. */
export function renderWeeklyRecapEmail(
  language: string | null | undefined,
  upcoming: EmailItem[],
  pastWeek: EmailItem[]
): EmailDocument {
  return layout(language, {
    subject: t(language, 'email.recap.subject'),
    heading: t(language, 'email.recap.heading'),
    sections: [
      { heading: t(language, 'email.recap.upcoming'), items: upcoming },
      { heading: t(language, 'email.recap.past'), items: pastWeek },
    ],
  })
}

/**
 * The dispatcher's own channel for a user who has never registered a device. It carries a single
 * notification, so it has no sections — but it is the same envelope as the rest.
 */
export function renderFallbackEmail(
  language: string | null | undefined,
  notification: { title: string; body: string }
): EmailDocument {
  return layout(language, {
    subject: notification.title,
    heading: notification.title,
    intro: notification.body,
    sections: [],
  })
}
