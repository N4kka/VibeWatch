import Foundation

/// Le identità di device dell'app. Sono **due**, e non sono la stessa cosa.
///
/// Prima esistevano sette copie del blocco "leggi-o-crea `deviceIdentifier`" sparse fra
/// `SupabaseClient`, `SyncEngine`, `UserPreferenceManager`, `DatabaseClipsService`, `ListManager` e
/// `MovieReactionView`, più tre letture diritte che, invece di crearlo, ripiegavano sulla stringa
/// `"unknown"` — attribuendo i dati di un device nuovo a un utente letteralmente chiamato così.
///
/// Le due identità **non si incrociano oggi**: ogni famiglia scrive e legge le proprie tabelle
/// (`installation` → `user_daily_quota`, `user_clip_signals`, `user_preferences`, `list_items`
/// anonimi; `database` → `personalized_discovery`). Il motivo per cui vale la pena nominarle qui è
/// che la prossima query che le unisce sarebbe silenziosamente vuota, e nulla nel codice segnalava
/// che ce ne fossero due.
enum DeviceIdentity {

    private static let installationKey = "deviceIdentifier"

    /// Identità dell'installazione, persistita in `UserDefaults`.
    ///
    /// Sopravvive alla cancellazione del database locale, **non** alla disinstallazione dell'app.
    /// È quella che finisce nelle colonne `device_id` sincronizzate con Supabase.
    static var installation: String {
        if let existing = UserDefaults.standard.string(forKey: installationKey) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: installationKey)
        return newId
    }

    /// Identità del **database locale**, dalla tabella `device_info`.
    ///
    /// ⚠️ Non è `installation`: è un UUID generato indipendentemente (e in minuscolo). Sopravvive
    /// alla disinstallazione solo se il file del DB sopravvive, e viene rigenerata se la tabella
    /// viene svuotata. Usare questa **solo** per i dati che già vi poggiano
    /// (`personalized_discovery`), mai per correlare con le tabelle di `installation`.
    static func database(_ db: SQLiteService = .shared) async -> String {
        await db.getOrCreateDeviceId()
    }
}
