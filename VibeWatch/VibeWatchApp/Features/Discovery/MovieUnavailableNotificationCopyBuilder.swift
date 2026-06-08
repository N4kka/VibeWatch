import Foundation

/// Pure unavailable/notify-me copy extracted from `MovieDetailView`.
enum MovieUnavailableNotificationCopyBuilder {

    static let notificationQuestion = "Would you like to be notified?"
    static let notifyButtonTitle = "Notify Me"
    static let alertTitle = "Notify Me"

    static func unavailableMessage(title: String) -> String {
        "Unluckily \(title) isn't currently available."
    }

    static func alertMessage(title: String) -> String {
        "We'll send you a notification as soon as '\(title)' is available for streaming, rent, or buy."
    }
}
