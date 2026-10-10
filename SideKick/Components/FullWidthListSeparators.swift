import SwiftUI

extension View {
    func fullWidthListSeparators() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions[.trailing] }
    }
}
