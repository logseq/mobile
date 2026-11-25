import Foundation
import UIKit
@testable import Logseq

@main struct ProfileAvatarCacheCheck {
    @MainActor static func main() async throws {
        let url = URL(string: "https://assets.logseq.com/avatar-cache-test-\(UUID().uuidString).png")!
        func store(width: CGFloat) {
            let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: 12)).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: 12))
            }
            LGProfileAvatarCache.store(image.pngData()!, for: url)
        }
        store(width: 12)
        let cached = await LGProfileAvatarCache.image(at: url)
        precondition(cached?.size.width == cached?.size.height && cached != nil)
        store(width: 24)
        let replaced = await LGProfileAvatarCache.image(at: url)
        precondition(replaced != nil && replaced!.size.width == 2 * replaced!.size.height)
        print("PASS: profile avatars load locally and a replacement takes effect immediately")
    }
}
