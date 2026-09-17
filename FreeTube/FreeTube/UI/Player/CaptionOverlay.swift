import SwiftUI

/// Draws the active caption line over the player surface, YouTube-style: white text on a
/// translucent black plate, bottom-centred, lifted a little while the transport controls are
/// showing so it never sits under the timeline.
@available(iOS 17.0, *)
struct CaptionOverlay: View {
    let text: String?
    let controlsVisible: Bool

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, controlsVisible ? 44 : 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: text)
        .allowsHitTesting(false)
    }
}
