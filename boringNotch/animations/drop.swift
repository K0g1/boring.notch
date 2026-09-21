//
//  drop.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import Defaults
import Foundation
import SwiftUI

enum StandardAnimations {
    static let minimumSpeed = 0.25
    static let maximumSpeed = 3.0
    static let defaultSpeed = 1.0

    static let gestureInteractive = Animation.interactiveSpring(
        response: 0.38,
        dampingFraction: 0.8,
        blendDuration: 0
    )

    static var speedMultiplier: Double {
        clampedSpeed(Defaults[.animationSpeedMultiplier])
    }

    static var openingResponse: Double {
        0.42 / speedMultiplier
    }

    static var closingResponse: Double {
        0.45 / speedMultiplier
    }

    static var opening: Animation? {
        guard Defaults[.enableOpeningAnimation] else { return nil }
        return .spring(response: openingResponse, dampingFraction: 0.8, blendDuration: 0)
    }

    static var closing: Animation? {
        guard Defaults[.enableOpeningAnimation] else { return nil }
        return .spring(response: closingResponse, dampingFraction: 1.0, blendDuration: 0)
    }

    static func clampedSpeed(_ speed: Double) -> Double {
        min(maximumSpeed, max(minimumSpeed, speed))
    }

    static func performOpening(_ updates: () -> Void) {
        perform(animation: opening, updates)
    }

    static func performClosing(_ updates: () -> Void) {
        perform(animation: closing, updates)
    }

    private static func perform(animation: Animation?, _ updates: () -> Void) {
        var transaction = Transaction(animation: animation)
        transaction.disablesAnimations = animation == nil
        withTransaction(transaction, updates)
    }
}

public class BoringAnimations {
    @Published var notchStyle: Style = .notch
    
    init() {
        self.notchStyle = .notch
    }
    
    var animation: Animation {
        if #available(macOS 14.0, *), notchStyle == .notch {
            Animation.spring(.bouncy(duration: 0.4))
        } else {
            Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
        }
    }
    
    // TODO: Move all animations to this file
    
}
