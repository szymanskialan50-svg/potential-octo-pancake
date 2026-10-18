import SwiftUI
import UIKit

/// Floating bottom bar in the iOS "Liquid Glass" style: a glass lens slides under the active tab, stretches
/// while you press it, follows your finger when you drag across the bar and settles with a spring.
/// The whole third of the bar is one big touch target.
struct LiquidTabBar: View {
    @Environment(\.accentInk) private var accentInk
    @Environment(\.ink) private var ink
    @Binding var selection: AppTab

    private struct Item: Identifiable {
        let tab: AppTab
        let icon: String
        let title: String
        var id: AppTab { tab }
    }

    private let items: [Item] = [
        Item(tab: .library, icon: "music.note.list", title: "Biblioteka"),
        Item(tab: .search, icon: "magnifyingglass", title: "Szukaj"),
        Item(tab: .settings, icon: "gearshape", title: "Ustawienia")
    ]

    @State private var dragX: CGFloat? = nil
    @State private var hoverIndex: Int? = nil

    private let barHeight: CGFloat = 64
    private let inset: CGFloat = 5

    private var selectedIndex: Int { items.firstIndex { $0.tab == selection } ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let inner = geo.size.width - inset * 2
            let tabW = inner / CGFloat(items.count)
            let pressed = dragX != nil
            let restX = inset + tabW * (CGFloat(selectedIndex) + 0.5)
            let centerX = lensCenter(restX: restX, tabW: tabW, inner: inner)
            let active = hoverIndex ?? selectedIndex

            ZStack {
                lens(pressed: pressed)
                    .frame(width: tabW, height: barHeight - inset * 2)
                    .position(x: centerX, y: barHeight / 2)
                    .animation(pressed
                               ? .interactiveSpring(response: 0.18, dampingFraction: 0.85)
                               : .spring(response: 0.45, dampingFraction: 0.7),
                               value: centerX)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        tabLabel(item, active: active == index, pressed: pressed)
                    }
                }
                .padding(.horizontal, inset)
            }
            .frame(width: geo.size.width, height: barHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let idx = index(at: value.location.x, tabW: tabW)
                        if hoverIndex != idx {
                            UISelectionFeedbackGenerator().selectionChanged()
                            hoverIndex = idx
                        }
                        dragX = value.location.x
                    }
                    .onEnded { value in
                        let idx = index(at: value.location.x, tabW: tabW)
                        let target = items[idx].tab
                        dragX = nil
                        hoverIndex = nil
                        if target != selection {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { selection = target }
                        }
                    }
            )
        }
        .frame(height: barHeight)
        .glass(Capsule())
    }

    private func lensCenter(restX: CGFloat, tabW: CGFloat, inner: CGFloat) -> CGFloat {
        guard let x = dragX else { return restX }
        let low = inset + tabW * 0.5
        let high = inset + inner - tabW * 0.5
        return min(max(x, low), high)
    }

    private func index(at x: CGFloat, tabW: CGFloat) -> Int {
        let raw = Int(((x - inset) / tabW).rounded(.down))
        return min(max(raw, 0), items.count - 1)
    }

    private func lens(pressed: Bool) -> some View {
        Capsule()
            .fill(ink.opacity(pressed ? 0.22 : 0.12))
            .overlay(Capsule().strokeBorder(ink.opacity(pressed ? 0.35 : 0.18), lineWidth: 0.8))
            .scaleEffect(x: pressed ? 1.1 : 1, y: pressed ? 1.12 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: pressed)
    }

    private func tabLabel(_ item: Item, active: Bool, pressed: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.system(size: 19, weight: .semibold))
                .symbolVariant(active ? .fill : .none)
                .symbolEffect(.bounce, value: active)
            Text(item.title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(active ? accentInk : ink.opacity(0.78))
        .scaleEffect(active && pressed ? 1.08 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
        .accessibilityAction { selection = item.tab }
    }
}
