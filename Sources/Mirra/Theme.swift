import SwiftUI

extension Color {
    /// Coral, from the app icon.
    static let brand = Color(red: 1.0, green: 0.37, blue: 0.33)
    static let brandWarm = Color(red: 1.0, green: 0.60, blue: 0.24)
}

extension ShapeStyle where Self == LinearGradient {
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [.brandWarm, .brand], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// View-local state without the `@State` macro (the Command Line Tools ship without its plugin).
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// Small colored dot with an optional soft pulse.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @StateObject private var on = LocalState(false)

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing {
                    Circle().stroke(color.opacity(0.6), lineWidth: 2)
                        .scaleEffect(on.value ? 2.2 : 1).opacity(on.value ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: on.value)
                }
            }
            .onAppear { on.value = true }
    }
}

/// A Liquid Glass capsule for short status text over the preview.
struct GlassPill<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(tint), in: .capsule)
    }
}

struct ToastView: View {
    let toast: Toast
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.symbol.contains("exclamation") ? Color.orange : Color.green)
                .font(.title3)
            Text(toast.message).font(.callout.weight(.medium))
            if let url = toast.fileURL {
                Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, toast.fileURL == nil ? 16 : 8)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The app icon as an image, for in-app branding.
struct AppIconImage: View {
    var size: CGFloat = 64

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
