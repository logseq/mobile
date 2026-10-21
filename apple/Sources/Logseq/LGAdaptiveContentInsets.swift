import SwiftUI

struct LGAdaptiveContentInsets: View {
    let content: AnyView
    let breakpoint: CGFloat
    let wideInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let inset = geometry.size.width >= breakpoint ? max(0, wideInset) : 0
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, inset)
        }
    }
}
