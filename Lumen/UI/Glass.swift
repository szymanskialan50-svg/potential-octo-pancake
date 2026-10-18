import SwiftUI
import UIKit
import MediaPlayer
import AVKit

// MARK: - Liquid glass (native on iOS 26+, material fallback before)

struct GlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.ink) private var ink
    let shape: S
    var interactive: Bool = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                content.glassEffect(Glass.regular.interactive(), in: shape)
            } else {
                content.glassEffect(Glass.regular, in: shape)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(ink.opacity(0.18), lineWidth: 0.6))
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, interactive: interactive))
    }

    func glassCard(radius: CGFloat = 22) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct GlassIconButton: View {
    @Environment(\.ink) private var ink
    let systemName: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .glass(Circle(), interactive: true)
                .frame(width: max(size, 48), height: max(size, 48))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System volume + AirPlay bridges

/// iOS has no API to set the system volume; a hidden MPVolumeView exposes its slider.
final class VolumeController: ObservableObject {
    @Published var level: Float = AVAudioSession.sharedInstance().outputVolume
    fileprivate weak var slider: UISlider?
    private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            let v = change.newValue ?? 0
            DispatchQueue.main.async { self?.level = v }
        }
    }

    func set(_ value: Float) {
        level = value
        slider?.value = value
    }
}

struct HiddenVolumeView: UIViewRepresentable {
    let controller: VolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.alpha = 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak v] in
            if controller.slider == nil {
                controller.slider = v?.subviews.compactMap { $0 as? UISlider }.first
            }
        }
        return v
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if controller.slider == nil {
            controller.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    var color: Color = .primary

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(color)
        v.activeTintColor = UIColor(color)
        return v
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = UIColor(color)
        view.activeTintColor = UIColor(color)
    }
}
