// A queued notification, and its text in the reader's language.
//
// Three consumers need exactly this and nothing else: the dispatcher (banner copy), the daily
// digest and the weekly recap (the same lines, in an email). It lives in _shared rather than
// inside process-notifications so the email jobs do not have to import the dispatcher's
// internals to render a sentence.

import { renderNotification, TemplateParams } from './i18n.ts'

export type NotificationRow = {
  id: string
  user_id: string
  notification_type: string
  title: string
  body: string
  media_id?: number | string | null
  media_type?: string | null
  retry_count?: number | null
  category?: string | null
  thread_id?: string | null
  created_at?: string | null
  template_key?: string | null
  template_params?: TemplateParams | null
}

/**
 * Rows queued before templates existed — or by a producer newer than the catalog — keep the
 * English copy their producer stored. That is why `title`/`body` are still written by every
 * generator and still NOT NULL: they are the floor this falls back to, never a dead column.
 */
export function localizedCopy(
  notification: NotificationRow,
  language: string | null | undefined
): { title: string; body: string } {
  const rendered = renderNotification(notification.template_key, notification.template_params, language)
  return rendered ?? { title: notification.title, body: notification.body }
}
