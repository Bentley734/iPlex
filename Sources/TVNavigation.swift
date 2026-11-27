#if os(tvOS)
import SwiftUI

struct TVNavigationRail<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.leading, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 8, content: content)
                    .padding(8)
            }
            .scrollIndicators(.hidden)
            .focusSection()
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 6)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.065), in: .rect(cornerRadius: 28))
    }
}

struct TVRailButton: View {
    let title: String
    let icon: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 30)
                Text(title).multilineTextAlignment(.leading)
            }
            .font(.system(size: 25, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(.horizontal, 14)
        }
        .buttonStyle(TVFocusStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TVFocusStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        FocusedLabel(configuration: configuration, selected: selected)
    }

    private struct FocusedLabel: View {
        @Environment(\.isFocused) private var focused
        let configuration: Configuration
        let selected: Bool

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? .white : .white.opacity(selected ? 0.22 : 0.08),
                            in: .rect(cornerRadius: 14))
                .overlay {
                    if selected && !focused {
                        RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.45), lineWidth: 2)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}
#endif
