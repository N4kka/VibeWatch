export type TimezonePreference = {
  exists: boolean
  timezone: string | null
}

export interface TimezonePreferenceStore {
  read(userId: string): Promise<TimezonePreference>
  /** Returns true only when this call inserted the row. */
  insertIfAbsent(userId: string, timezone: string): Promise<boolean>
  /** Returns true only when this call changed a still-null timezone. */
  updateIfUnset(userId: string, timezone: string): Promise<boolean>
}

export type ImportedTimezoneOutcome =
  | 'non_presente'
  | 'applicato'
  | 'gia_impostato'
  | `errore: ${string}`

/**
 * Applies TV Time's timezone only while the user has not chosen one in VibeWatch.
 *
 * Both writes report whether they actually changed a row. This matters because a preferences
 * edit can race the import between its read and write: the conditional write keeps the explicit
 * choice, while the boolean keeps the import report honest.
 */
export async function applyImportedTimezone(
  timezone: unknown,
  userId: string,
  store: TimezonePreferenceStore,
): Promise<ImportedTimezoneOutcome> {
  if (typeof timezone !== 'string' || timezone.length === 0) return 'non_presente'

  try {
    const current = await store.read(userId)
    if (current.exists && current.timezone !== null) return 'gia_impostato'

    if (current.exists) {
      return await store.updateIfUnset(userId, timezone) ? 'applicato' : 'gia_impostato'
    }

    if (await store.insertIfAbsent(userId, timezone)) return 'applicato'

    // Someone created the preferences row after our read. Re-read it and only fill a still-null
    // timezone; never turn a uniqueness race into an error or an overwrite.
    const raced = await store.read(userId)
    if (raced.exists && raced.timezone === null) {
      return await store.updateIfUnset(userId, timezone) ? 'applicato' : 'gia_impostato'
    }
    return 'gia_impostato'
  } catch (error) {
    return `errore: ${error instanceof Error ? error.message : String(error)}`
  }
}
