import SwiftUI

enum StopChoice { case save, discard, keep }

/// The Esc prompt while recording: the recording is paused until you pick one.
struct StopPromptView: View {
    let title: String
    let elapsed: String
    let choose: (StopChoice) -> Void
    @State private var pulse = false
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle().fill(.orange).frame(width: 9, height: 9)
                    .shadow(color: .orange, radius: pulse ? 6 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
                Text("\(title.uppercased())  ·  PAUSED  ·  \(elapsed)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text("Stop recording?")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 10) {
                choice("Save", key: "↩", symbol: "checkmark.circle.fill", color: Color(red: 0.2, green: 0.8, blue: 0.5), .save)
                choice("Discard", key: "D", symbol: "trash.fill", color: Color(red: 1, green: 0.32, blue: 0.35), .discard)
                choice("Keep going", key: "esc", symbol: "play.fill", color: Color(white: 0.55), .keep)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.07).opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        )
        .scaleEffect(shown ? 1 : 0.9)
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pulse = true
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { shown = true }
        }
    }

    private func choice(_ label: String, key: String, symbol: String, color: Color, _ value: StopChoice) -> some View {
        Button { choose(value) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(key)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.55)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
