//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
import AppKit
import Cocoa
import SwiftUI

final class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var isPlaying = false
    private static let animationKey = "audioSpectrum.scale"
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let barWidth: CGFloat = 2
        let barCount = 4
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            layer?.addSublayer(barLayer)
        }

        resetBars()
    }
    
    private func startAnimating() {
        for (index, barLayer) in barLayers.enumerated() {
            guard barLayer.animation(forKey: Self.animationKey) == nil else { continue }

            let values: [CGFloat] = [0.35, 0.8, 0.45, 1.0, 0.55, 0.35]
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = values.rotated(by: index)
            animation.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
            animation.duration = 1.5 + (Double(index) * 0.08)
            animation.calculationMode = .cubic
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = true
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 10,
                    maximum: 30,
                    preferred: 15
                )
            }
            barLayer.add(animation, forKey: Self.animationKey)
        }
    }
    
    private func stopAnimating() {
        resetBars()
    }
    
    private func resetBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for barLayer in barLayers {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, 0.35, 1)
        }
        CATransaction.commit()
    }
    
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    deinit {
        stopAnimating()
    }
}

private extension Array {
    func rotated(by offset: Int) -> [Element] {
        guard !isEmpty else { return self }
        let normalizedOffset = offset % count
        return Array(self[normalizedOffset...]) + Array(self[..<normalizedOffset])
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    
    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }
    
    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ nsView: AudioSpectrum, coordinator: ()) {
        nsView.setPlaying(false)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}
