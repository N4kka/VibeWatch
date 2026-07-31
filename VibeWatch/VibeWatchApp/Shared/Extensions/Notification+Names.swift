import Foundation

extension Notification.Name {
    /// §9.1: l'AI non e' piu' un tab ma un pannello. Il nome resta per non rompere i chiamanti
    /// — sono deep link e scorciatoie, e rinominarlo avrebbe rotto quelli senza guadagnare nulla.
    static let navigateToAITab = Notification.Name("navigateToAITab")
    static let navigateToTrackingTab = Notification.Name("navigateToTrackingTab")
    static let presentProPaywall = Notification.Name("presentProPaywall")
}
