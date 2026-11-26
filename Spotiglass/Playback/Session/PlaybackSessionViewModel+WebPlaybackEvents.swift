import Foundation

@MainActor
extension PlaybackSessionViewModel {
    func handle(_ envelope: MusicPlaybackEventEnvelope) {
        guard ownsPlaybackHostGeneration(envelope.hostGeneration) else {
            SpotiglassLog.info(
                .playback,
                "Ignoring stale SDK event generation=\(envelope.hostGeneration.rawValue) current=\(playbackHostGeneration.rawValue)"
            )
            return
        }
        handleCurrentPlaybackEvent(envelope.event)
    }

    private func handleCurrentPlaybackEvent(_ event: MusicPlaybackEvent) {
        switch event {
        case .ready(let deviceID):
            SpotiglassLog.info(
                .playback,
                "SDK ready deviceID=\(deviceID) previousDeviceID=\(self.deviceID ?? "<nil>") autoResumeOnNextReady=\(autoResumeOnNextReady)"
            )
            // A reloaded SDK page registers a new device, so a late `ready` for
            // a superseded one comes from an old page. A player that keeps one
            // constant id reports that same id on every reconnect, and the
            // event's generation already fences stale lifecycles.
            if provider.capabilities.contains(.reloadablePlayer),
                supersededSDKDeviceIDs.contains(deviceID)
            {
                guard self.deviceID == nil, reclaimableSDKDeviceID == deviceID else {
                    SpotiglassLog.info(.playback, "Ignoring stale SDK ready deviceID=\(deviceID)")
                    return
                }
                supersededSDKDeviceIDs.remove(deviceID)
            }
            cancelPlaybackHostConnectTimeout()
            reclaimableSDKDeviceID = nil
            let previousSDKDeviceID = self.deviceID
            let wasRemotePlaybackActive = isRemotePlaybackActive
            let shouldRefreshTransportState = !(previousSDKDeviceID == deviceID && isTransportStateKnown)
            if shouldRefreshTransportState {
                setTransportStateKnown(false)
            }
            if let previousSDKDeviceID, previousSDKDeviceID != deviceID {
                supersededSDKDeviceIDs.insert(previousSDKDeviceID)
            }
            if previousSDKDeviceID != deviceID {
                hasTransferredPlaybackToCurrentDevice = false
            }
            self.deviceID = deviceID
            if activePlaybackDeviceID == nil || activePlaybackDeviceID == previousSDKDeviceID {
                setActivePlaybackDeviceID(deviceID)
            }
            if !wasRemotePlaybackActive && !isRemotePlaybackActive {
                setConnectionState(.ready(deviceID: deviceID))
            }
            refreshTrayOutputSymbol()
            let persistedVolume = playbackVolume
            let persistedVolumeMutationVersion =
                shouldRefreshTransportState
                ? beginPendingPlaybackVolumeMutation(target: persistedVolume)
                : volumeMutationVersion
            let persistedVolumeSendSerial = playbackVolumeSendSerial
            let initialTransportSyncTask = shouldRefreshTransportState ? scheduleTransportSync() : nil
            let shouldAutoResume = autoResumeOnNextReady
            playbackHostAutoResumeTask?.cancel()
            playbackHostAutoResumeTask = nil
            playbackHostAutoResumeSerial &+= 1
            let autoResumeSerial = playbackHostAutoResumeSerial
            let generation = playbackHostGeneration
            playbackHostAutoResumeTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation),
                        self.playbackHostAutoResumeSerial == autoResumeSerial
                    {
                        self.playbackHostAutoResumeTask = nil
                        if shouldAutoResume {
                            self.autoResumeOnNextReady = false
                        }
                    }
                }
                guard self.ownsPlaybackHostGeneration(generation),
                    self.playbackHostAutoResumeSerial == autoResumeSerial,
                    !Task.isCancelled
                else { return }
                await self.syncPlaybackVolumeToWebPlayer(
                    persistedVolume,
                    mutationVersion: persistedVolumeMutationVersion,
                    sendSerial: persistedVolumeSendSerial,
                    generation: generation
                )
                guard self.ownsPlaybackHostGeneration(generation),
                    self.playbackHostAutoResumeSerial == autoResumeSerial,
                    !Task.isCancelled
                else { return }
                if shouldAutoResume {
                    await self.autoResumeFromStaleSpotiglassDeviceIfNeeded(
                        targetDeviceID: deviceID,
                        initialTransportSyncTask: initialTransportSyncTask,
                        generation: generation
                    )
                }
            }
        case .notReady(let deviceID):
            SpotiglassLog.info(.playback, "SDK not_ready deviceID=\(deviceID)")
            if self.deviceID == deviceID {
                supersededSDKDeviceIDs.insert(deviceID)
                reclaimableSDKDeviceID = deviceID
            }
            guard self.deviceID == deviceID else {
                SpotiglassLog.info(
                    .playback,
                    "Ignoring stale SDK not_ready deviceID=\(deviceID) currentDeviceID=\(self.deviceID ?? "<nil>")")
                return
            }
            self.deviceID = nil
            setTransportStateKnown(false)
            if activePlaybackDeviceID == deviceID {
                setActivePlaybackDeviceID(nil)
            }
            hasTransferredPlaybackToCurrentDevice = false
            clearPendingSkipCommand()
            endSkipPreview()
            sdkNextTracks = []
            sdkPreviousTracks = []
            setConnectionState(.unavailable(LocalizedText(SpotiglassL10n.string("error.playback.deviceLost.message"))))
            playbackHostRecoveryTask?.cancel()
            playbackHostRecoveryTask = nil
            playbackHostRecoverySerial &+= 1
            let recoverySerial = playbackHostRecoverySerial
            let generation = playbackHostGeneration
            playbackHostRecoveryTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation),
                        self.playbackHostRecoverySerial == recoverySerial
                    {
                        self.playbackHostRecoveryTask = nil
                    }
                }
                await self.attemptPlaybackHostRecovery(cause: .notReady, generation: generation)
            }
        case .stateChanged(let nowPlaying, let isPaused, let nextTracks, let previousTracks):
            if isRemotePlaybackActive {
                // The embedded SDK is intentionally idle while another
                // Connect device owns playback. Its state_changed events must
                // not replace the Web API snapshot in the transport.
                SpotiglassLog.info(.playback, "Ignoring SDK state_changed while remote device is active")
                return
            }
            let suppressed = shouldSuppressStaleStateChange(nowPlaying: nowPlaying, isPlaying: !isPaused)
            SpotiglassLog.info(
                .playback,
                "SDK state_changed nowPlayingURI=\(nowPlaying?.uri ?? "<nil>") isPaused=\(isPaused) nextCount=\(nextTracks.count) pendingPlayURI=\(pendingPlayURI ?? "<nil>") suppressed=\(suppressed)"
            )
            observeSkipAdvance(nowPlayingURI: nowPlaying?.uri)
            if suppressed {
                return
            }
            if let nowPlaying {
                pageReportedPlayState = isPaused ? .paused(nowPlaying) : .playing(nowPlaying)
            }
            // Still the song a skip left: the bar keeps the song it went to until Spotify has it.
            if holdsReportForSkipPreview(nowPlaying, event: event) {
                return
            }
            // A report without a track (the player going away) always goes through.
            guard nowPlaying == nil || acceptsPushedPlayState(isPlaying: !isPaused) else {
                heldBackPageReport = MusicPlaybackEventEnvelope(event: event, hostGeneration: playbackHostGeneration)
                SpotiglassLog.info(
                    .playback, "Ignoring SDK state_changed isPaused=\(isPaused) older than the last play/pause")
                return
            }
            cancelPlaybackHostConnectTimeout()
            let authoritativeState: PlaybackConnectionState =
                isPaused
                ? .paused(nowPlaying)
                : .playing(nowPlaying ?? fallbackNowPlaying())
            updateSeekOwnership(from: authoritativeState)
            if failedSeekOwnershipKey == seekOwnershipKey {
                return
            }
            sdkNextTracks = nextTracks
            sdkPreviousTracks = previousTracks
            let effectiveNowPlaying = applyPendingSeekSuppression(to: nowPlaying)
            if effectiveNowPlaying != nil, !isRemotePlaybackActive {
                hasTransferredPlaybackToCurrentDevice = true
            }
            setConnectionState(
                isPaused ? .paused(effectiveNowPlaying) : .playing(effectiveNowPlaying ?? fallbackNowPlaying()))
        case .playerCommandFinished(let command, let id):
            handleInAppCommandFinished(command, id: id)
        case .playerCommandFailed(let command, let message, let id):
            // A refused pause or play goes back instead of replacing the bar with an error (#437).
            if Self.isPlayPauseCommand(command) {
                handleInAppPlayPauseFailure(command: command, message: message, id: id)
            } else {
                handleCurrentPlaybackEvent(.playbackError(message))
            }
        case .initializationError(let message):
            cancelPlaybackHostConnectTimeout()
            // Its error says what to do; a report held back for a press mustn't replace it (#437).
            clearPushedPlayStateExpectation()
            showPlaybackError(
                nil, while: "starting the Spotify player (SDK initialization)",
                context: [.public("sdkMessage", message)],
                ErrorMessage(
                    title: SpotiglassL10n.string("error.playback.couldNotStart.title"),
                    // The SDK's text is English whatever the app's language (#470); it's in the log.
                    message: SpotiglassL10n.string("error.playback.connectionTimeout.message"),
                    action: .reconnect
                ))
            playbackHostRecoveryTask?.cancel()
            playbackHostRecoveryTask = nil
            playbackHostRecoverySerial &+= 1
            let recoverySerial = playbackHostRecoverySerial
            let generation = playbackHostGeneration
            playbackHostRecoveryTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.ownsPlaybackHostGeneration(generation),
                        self.playbackHostRecoverySerial == recoverySerial
                    {
                        self.playbackHostRecoveryTask = nil
                    }
                }
                await self.attemptPlaybackHostRecovery(cause: .initializationError, generation: generation)
            }
        case .authenticationError(let message):
            cancelPlaybackHostConnectTimeout()
            // Its error says what to do; a report held back for a press mustn't replace it (#437).
            clearPushedPlayStateExpectation()
            showPlaybackError(
                nil, while: "signing the Spotify player in", context: [.public("sdkMessage", message)],
                ErrorMessage(
                    title: SpotiglassL10n.string("error.playback.signInAgain.title"),
                    message: SpotiglassL10n.string("error.playback.signInAgain.message"),
                    action: .reauthenticate
                ))
        case .signInPaused(let message):
            cancelPlaybackHostConnectTimeout()
            clearPushedPlayStateExpectation()
            // Reconnect, never "sign in again": the sign-in still works and the app starts the
            // player again by itself once it has refreshed (#593).
            showPlaybackError(
                nil, while: "starting the Spotify player while the sign-in is paused",
                context: [.public("sdkMessage", message)], level: .info,
                ErrorMessage(
                    title: SpotiglassL10n.string("app.connection.paused.title"),
                    message: message,
                    action: .reconnect
                ))
        case .accountError(let message):
            cancelPlaybackHostConnectTimeout()
            // Its error says what to do; a report held back for a press mustn't replace it (#437).
            clearPushedPlayStateExpectation()
            showPlaybackError(
                nil, while: "starting the Spotify player (account)", context: [.public("sdkMessage", message)],
                ErrorMessage(
                    title: SpotiglassL10n.string("error.playback.premium.title"),
                    message: SpotiglassL10n.string("error.playback.premium.message"),
                    action: nil
                ))
        case .playbackError(let message):
            cancelPlaybackHostConnectTimeout()
            clearPushedPlayStateExpectation()
            finishInAppCommand()
            showPlaybackError(
                nil, while: "playing in the Spotify player", context: [.public("sdkMessage", message)],
                ErrorMessage(
                    title: SpotiglassL10n.string("error.playback.error.title"),
                    message: SpotiglassL10n.string("error.playback.spotify.failed"),
                    action: .retryTransfer
                ))
        case .log(let message):
            SpotiglassLog.info(.playback, "Spotify playback SDK: \(message)")
        case .playerChanged:
            // A pause from a media key, Control Center or AirPods shows at once instead of at
            // the next poll, 2 to 20 s later (#645). The read goes through the same checks as
            // the poll's, so a status from before a press can't undo it.
            guard isPlayerStateRead, !isRemotePlaybackActive else { return }
            // Once a read showed the last pause or play applied, the player changing again is
            // something new, not its state trailing that command: the settle window that hides
            // trailing reads would hide it until the next poll.
            if localCommandConfirmedByRead, pendingPlayTransition == nil, skipLeftItemURI == nil {
                localMutationSettleTicksRemaining = 0
                localCommandExpectsPlaying = nil
                localCommandConfirmedByRead = false
                playPauseReadHoldUntil = nil
            }
            scheduleTransportSync()
        }
    }

    private func syncPlaybackVolumeToWebPlayer(
        _ volume: Double,
        mutationVersion: UInt64,
        sendSerial: UInt64,
        generation: PlaybackHostGeneration
    ) async {
        guard ownsPlaybackHostGeneration(generation), !Task.isCancelled else { return }
        guard mutationVersion == volumeMutationVersion,
            sendSerial == playbackVolumeSendSerial
        else { return }
        try? await provider.setVolume(volume, generation: generation)
    }
}
