import SwiftUI

struct OverlayCapsuleView: View {

    let icon: CapsuleIcon?
    let text: String
    let stableText: String?
    let progress: CGFloat?

    enum CapsuleIcon {
        case pulse(systemName: String, color: Color)
        case plain(systemName: String, color: Color)
    }

    private enum Constants {
        static let iconSize: CGFloat = 22
        static let iconSpacing: CGFloat = 10
        static let textFontSize: CGFloat = 13
        static let smallIconFontSize: CGFloat = 11
        static let mediumIconFontSize: CGFloat = 14
        static let verticalPadding: CGFloat = 10
        static let textPadding: CGFloat = 16
        static let iconOnlyPadding: CGFloat = 10
        static let progressPadding: CGFloat = 32
        static let backgroundWhite: CGFloat = 0.12
        static let processingBackgroundWhite: CGFloat = 0.10
        static let backgroundAlpha: CGFloat = 0.92
        static let progressFillWhite: CGFloat = 0.28
        static let progressAnimationDuration: Double = 0.1
        static let pulseTargetScale: CGFloat = 1.5
        static let pulseDuration: Double = 0.8
        static let pulseCircleOpacity: Double = 0.3
    }

    @State private var pulseScale: CGFloat = 1.0

    private var hasIcon: Bool { icon != nil }
    private var hasText: Bool { !text.isEmpty }
    private var isProgress: Bool { progress != nil }

    var body: some View {
        HStack(spacing: (hasIcon && hasText) ? Constants.iconSpacing : 0) {
            if let icon {
                iconView(icon)
            }
            if hasText {
                labelView
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, Constants.verticalPadding)
        .background(capsuleBackground)
        .clipShape(Capsule())
        .onAppear {
            if case .pulse = icon {
                withAnimation(.easeInOut(duration: Constants.pulseDuration).repeatForever(autoreverses: true)) {
                    pulseScale = Constants.pulseTargetScale
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func iconView(_ icon: CapsuleIcon) -> some View {
        Group {
            switch icon {
            case .pulse(let systemName, let color):
                ZStack {
                    Circle()
                        .fill(color.opacity(Constants.pulseCircleOpacity))
                        .frame(width: Constants.iconSize, height: Constants.iconSize)
                        .scaleEffect(pulseScale)
                    Image(systemName: systemName)
                        .font(.system(size: Constants.smallIconFontSize, weight: .semibold))
                        .foregroundColor(color)
                }
            case .plain(let systemName, let color):
                Image(systemName: systemName)
                    .font(.system(size: Constants.mediumIconFontSize, weight: .medium))
                    .foregroundColor(color)
            }
        }
        .frame(width: Constants.iconSize, height: Constants.iconSize)
    }

    private var labelView: some View {
        ZStack(alignment: .leading) {
            if let stableText {
                Text(stableText)
                    .font(.system(size: Constants.textFontSize, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .hidden()
            }
            Text(text)
                .font(.system(size: Constants.textFontSize, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var capsuleBackground: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: NSColor(
                        white: isProgress ? Constants.processingBackgroundWhite : Constants.backgroundWhite,
                        alpha: Constants.backgroundAlpha
                    )))
                if let progress {
                    Capsule()
                        .fill(Color(nsColor: NSColor(white: Constants.progressFillWhite, alpha: Constants.backgroundAlpha)))
                        .frame(width: geo.size.width * progress)
                        .animation(.linear(duration: Constants.progressAnimationDuration), value: progress)
                }
            }
        }
    }

    private var horizontalPadding: CGFloat {
        if isProgress { return Constants.progressPadding }
        return hasText ? Constants.textPadding : Constants.iconOnlyPadding
    }
}
