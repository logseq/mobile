import ImageIO
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
        let photo = await Self.profileImage(at: url) ?? Self.initialAvatar(String(initial).uppercased())
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

    private static func profileImage(at url: URL?) async -> INImage? {
        let supportedHosts = ["logseq-user-public-metadata-bucket-prod.s3.amazonaws.com", "assets.logseq.com", "assets.logseq.io", "avatars.githubusercontent.com", "lh3.googleusercontent.com"]
        guard let url, url.scheme == "https", let host = url.host, supportedHosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            let limit = 128 * 1024
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= limit, response.mimeType?.hasPrefix("image/") == true else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { return nil }
                data.append(byte)
            }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  let png = UIImage(cgImage: thumbnail).pngData() else { return nil }
            return INImage(imageData: png)
        } catch {
            return nil
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
