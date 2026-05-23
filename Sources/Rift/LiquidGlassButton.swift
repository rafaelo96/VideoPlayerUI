import SwiftUI

struct LiquidGlassButton: View {
    enum Size {
        case compact
        case largeIcon
        case metric
    }

    var title: String?
    var subtitle: String?
    var systemName: String?
    var isActive = false
    var size: Size = .compact
    var action: () -> Void

    var body: some View {
        // One button component supports both SF Symbol controls and compact text toggles.
        Button(action: action) {
            label
            .foregroundStyle(isActive ? .white : .white.opacity(0.82))
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        isActive
                            ? AnyShapeStyle(LinearGradient(
                                colors: [
                                    Color(red: 0.16, green: 0.50, blue: 0.96).opacity(0.26),
                                    Color(red: 0.10, green: 0.34, blue: 0.86).opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            : AnyShapeStyle(.white.opacity(size == .metric ? 0.045 : 0.0))
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(size == .metric ? 0.18 : 0.0), lineWidth: 1)
            }
            .shadow(color: isActive ? .blue.opacity(0.16) : .black.opacity(0.06), radius: 9, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var label: some View {
        switch size {
        case .largeIcon:
            Image(systemName: systemName ?? "")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 26, height: 26)

        case .metric:
            HStack(spacing: 8) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 15)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 80, height: 37)

        case .compact:
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            } else if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(height: 34)
                    .padding(.horizontal, 10)
            }
        }
    }

    private var cornerRadius: CGFloat {
        size == .metric ? 9 : 13
    }
}
