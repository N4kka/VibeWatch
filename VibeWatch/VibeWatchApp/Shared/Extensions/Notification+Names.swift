import Foundation

extension Notification.Name {
    /// §9.1: l'AI non e' piu' un tab ma un pannello. Il nome resta per non rompere i chiamanti
    /// — sono deep link e scorciatoie, e rinominarlo avrebbe rotto quelli senza guadagnare nulla.
    static let navigateToAITab = Notification.Name("navigateToAITab")
    static let navigateToTrackingTab = Notification.Name("navigateToTrackingTab")
    /// Social feed M3: dove atterra il tap su una push social che non punta a una card
    /// (il "ti segue" — l'attore non viaggia nel payload).
    static let navigateToSocialTab = Notification.Name("navigateToSocialTab")
    static let presentProPaywall = Notification.Name("presentProPaywall")

    /// I dati locali dell'account precedente sono stati cancellati (logout o cambio utente).
    /// Le view già istanziate tengono in memoria quello che avevano letto: chi mostra cronologia
    /// o attività si azzera qui, o resterebbe a schermo la roba dell'utente uscito.
    static let localUserDataDidReset = Notification.Name("localUserDataDidReset")
}
