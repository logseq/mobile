import Intents
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        let delivery = Delivery(content: request.content, handler: handler)
        Task { delivery.handler(await Self.displayContent(delivery.content)) }
    }

    // Transfer the read-only request content and the system's async completion callback to one task.
    private struct Delivery: @unchecked Sendable {
        let content: UNNotificationContent
        let handler: (UNNotificationContent) -> Void
    }

    private static func displayContent(_ content: UNNotificationContent) async -> UNNotificationContent {
        guard let senderID = content.userInfo["senderId"] as? String, UUID(uuidString: senderID) != nil,
              let name = content.userInfo["senderName"] as? String, let initial = name.first else { return content }

        let url = (content.userInfo["avatarURL"] as? String).flatMap(URL.init(string:))
        let image = if let url { await LGProfileAvatarCache.image(at: url) } else { nil as UIImage? }
        let photo = image?.pngData().map(INImage.init(imageData:)) ?? Self.initialAvatar(String(initial).uppercased())
        let sender = INPerson(personHandle: INPersonHandle(value: senderID, type: .unknown),
                              nameComponents: nil, displayName: name, image: photo,
                              contactIdentifier: nil, customIdentifier: nil, isMe: false,
                              suggestionType: .none)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                        content: content.body, speakableGroupName: nil,
                                        conversationIdentifier: content.userInfo["graphId"] as? String,
                                        serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return (try? content.updating(from: intent)) ?? content
    }

    private static func initialAvatar(_ initial: String) -> INImage? {
        let size = CGSize(width: 128, height: 128)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(UIColor(red: 0.05, green: 0.33, blue: 0.35, alpha: 1).cgColor)
            context.cgContext.fillEllipse(in: bounds)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 58, weight: .semibold), .foregroundColor: UIColor.white,
            ]
            let label = NSAttributedString(string: initial, attributes: attributes)
            let labelSize = label.size()
            label.draw(at: CGPoint(x: (size.width - labelSize.width) / 2, y: (size.height - labelSize.height) / 2))
        }
        return image.pngData().map(INImage.init(imageData:))
    }
}
