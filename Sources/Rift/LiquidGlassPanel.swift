import AppKit
import SwiftUI

struct LiquidGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 28
    var material: NSVisualEffectView.Material = .hudWindow
    @ViewBuilder var content: Content

    var body: some View {
        // Native blur with restrained optical layers keeps the panel glassy without adding new chrome.
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .background {
                        NativeVisualEffectView(material: material)
                            .opacity(0.26)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.10),
                                        Color(red: 0.16, green: 0.48, blue: 0.95).opacity(0.035),
                                        .white.opacity(0.006)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.black.opacity(0.006))
                            .blendMode(.multiply)
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.36),
                                .white.opacity(0.08),
                                Color(red: 0.18, green: 0.48, blue: 0.95).opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.7)
                    .padding(1)
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.025), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .padding(.horizontal, 22)
                    .padding(.top, 1)
                    .blur(radius: 0.35)
            }
            .shadow(color: .black.opacity(0.13), radius: 20, x: 0, y: 12)
            .shadow(color: Color(red: 0.12, green: 0.42, blue: 0.92).opacity(0.08), radius: 22, x: 0, y: 0)
            .compositingGroup()
    }
}
