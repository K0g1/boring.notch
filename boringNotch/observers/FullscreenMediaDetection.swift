//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    
    private var monitorTask: Task<Void, Never>?
    private var preferenceCancellable: AnyCancellable?
    private var monitoringGeneration = 0
    
    private init() {
        preferenceCancellable = Defaults.publisher(.hideNotchOption)
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] option in
                guard let self else { return }
                if option == .never {
                    self.stopMonitoring()
                } else {
                    self.startMonitoring()
                }
            }

        if Defaults[.hideNotchOption] != .never {
            startMonitoring()
        }
    }
    
    deinit {
        monitorTask?.cancel()
        preferenceCancellable?.cancel()
    }
    
    func startMonitoring() {
        guard monitorTask == nil, Defaults[.hideNotchOption] != .never else { return }
        monitoringGeneration += 1
        let generation = monitoringGeneration
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                guard !Task.isCancelled else { break }
                updateStatus(with: spaces)
            }
            if monitoringGeneration == generation {
                monitorTask = nil
            }
        }
    }

    func stopMonitoring() {
        monitoringGeneration += 1
        monitorTask?.cancel()
        monitorTask = nil
        fullscreenStatus.removeAll()
    }
    
    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        var newStatus: [String: Bool] = [:]
        
        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if Defaults[.hideNotchOption] == .nowPlayingOnly, let musicSourceBundle = MusicManager.shared.bundleIdentifier  {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }
        
        self.fullscreenStatus = newStatus
    }
}
