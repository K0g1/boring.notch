//
//  MediaControllerProtocol.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import AppKit
import Combine

protocol MediaControllerProtocol: AnyObject, ObservableObject {
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var supportsVolumeControl: Bool { get }
    var supportsFavorite: Bool { get }

    /// Starts subscriptions and owned background resources. Implementations
    /// must be idempotent because controller selection can be requested more
    /// than once while preferences are changing.
    func start() async

    /// Stops every subscription, task, timer, pipe and child process owned by
    /// the controller. Once this returns, the controller must be quiescent.
    func stop() async

    /// Performs the non-suspending portion of shutdown. This is called from
    /// `applicationWillTerminate`, where an asynchronous task is not
    /// guaranteed another scheduling opportunity before the process exits.
    func stopImmediately()
    
    func setFavorite(_ favorite: Bool) async
    func play() async
    func pause() async
    func seek(to time: Double) async
    func nextTrack() async
    func previousTrack() async
    func togglePlay() async
    func toggleShuffle() async
    func toggleRepeat() async
    func setVolume(_ level: Double) async
    func isActive() -> Bool
    func updatePlaybackInfo() async
}

extension MediaControllerProtocol {
    func stopImmediately() {}
}
