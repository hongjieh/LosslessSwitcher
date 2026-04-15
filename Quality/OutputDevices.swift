//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import CoreAudioTypes
import Foundation
import MediaRemoteAdapter
import SimplyCoreAudio

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    
    private let coreAudio = SimplyCoreAudio()
    private let logReader = LogReader()
    private let snapshotReader = MusicTrackSnapshotReader()
    private let localFileFormatResolver = LocalFileFormatResolver()
    
    private let bootstrapQueue = DispatchQueue(label: "bootstrapQueue", qos: .utility)
    private let pairHandlingQueue = DispatchQueue(label: "phq", qos: .userInteractive)
    private let processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var entryStreamReceiver: AnyCancellable?
    private var activationStreamReceiver: AnyCancellable?
    
    private var recentEntries = [CMEntry]()
    private var latestNamedEntries = [String: CMEntry]()
    private var currentSession: PlaybackSession?
    private var isSwitchingFormat = false
    private var needsReapplyAfterSwitch = false
    private let maxSwitchVerificationRetries = 2
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    private(set) var previousTrack: MediaTrack?
    private(set) var currentTrack: MediaTrack?
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        self.logReader.spawnProcessIfNeeded()
        bootstrapRecentEntries()
        bootstrapCurrentPlaybackSession()
        
        entryStreamReceiver = logReader.entryStream
            .receive(on: pairHandlingQueue)
            .sink { [weak self] entry in
                self?.handleLogEntry(entry)
            }
        
        activationStreamReceiver = logReader.activationStream
            .receive(on: pairHandlingQueue)
            .sink { [weak self] activation in
                self?.handleTrackActivation(activation)
            }
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink { [weak self] _ in
                guard let self else { return }
                self.outputDevices = self.coreAudio.allOutputDevices
            }
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink { [weak self] _ in
                guard let self else { return }
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
                self.scheduleReapplyCurrentSessionFormat()
            }
        
        outputSelectionCancellable = $selectedOutputDevice.sink { [weak self] _ in
            guard let self else { return }
            self.getDeviceSampleRate()
            self.scheduleReapplyCurrentSessionFormat()
        }
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink { [weak self] newValue in
            guard let self else { return }
            self.enableBitDepthDetection = newValue
            self.scheduleReapplyCurrentSessionFormat()
        }
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        outputSelectionCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        entryStreamReceiver?.cancel()
        activationStreamReceiver?.cancel()
        logReader.stop()
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = activeDevice()
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func trackDidChange(_ newTrack: TrackInfo) {
        let mediaTrack = MediaTrack(trackInfo: newTrack)
        validateAndBeginTrackChange(newTrack, mediaTrack: mediaTrack, attempt: 0)
    }
    
    private func activeDevice() -> AudioDevice? {
        if let selectedUID = selectedOutputDevice?.uid {
            return AudioDevice.lookup(by: selectedUID) ?? selectedOutputDevice
        }
        
        if let defaultUID = coreAudio.defaultOutputDevice?.uid {
            return AudioDevice.lookup(by: defaultUID) ?? coreAudio.defaultOutputDevice
        }
        
        return coreAudio.defaultOutputDevice ?? defaultOutputDevice
    }

    private func scheduleReapplyCurrentSessionFormat() {
        pairHandlingQueue.async { [weak self] in
            guard let self else { return }
            if self.isSwitchingFormat {
                self.needsReapplyAfterSwitch = true
                return
            }
            self.reapplyCurrentSessionFormatIfNeeded()
        }
    }
    
    private func handleLogEntry(_ entry: CMEntry) {
        updateNamedEntryCache(with: entry)
        recentEntries.append(entry)
        pruneRecentEntries(referenceDate: entry.date)
        matchCurrentSessionFromBufferedEntries()
    }
    
    private func handleTrackActivation(_ activation: TrackActivation) {
        beginSession(
            track: MediaTrack(title: activation.trackName),
            startedAt: activation.date,
            historyLookback: 3600,
            resolveSnapshot: true
        )
    }

    private func validateAndBeginTrackChange(_ trackInfo: TrackInfo, mediaTrack: MediaTrack, attempt: Int) {
        processQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshotReader.fetchCurrentTrack()
            
            self.pairHandlingQueue.async { [weak self] in
                guard let self else { return }
                
                if let snapshot, !snapshot.roughlyMatches(mediaTrack) {
                    if attempt == 0 {
                        self.processQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                            self?.validateAndBeginTrackChange(trackInfo, mediaTrack: mediaTrack, attempt: 1)
                        }
                    }
                    else {
                        NSLog(
                            "[Session] ignored stale title=%@ current=%@",
                            mediaTrack.title ?? "nil",
                            snapshot.name ?? "nil"
                        )
                    }
                    return
                }
                
                self.beginSession(
                    track: mediaTrack,
                    startedAt: Self.sessionStartDate(from: trackInfo),
                    historyLookback: Self.historyLookbackSeconds(from: trackInfo),
                    resolveSnapshot: true
                )
            }
        }
    }
    
    private func bootstrapRecentEntries() {
        bootstrapQueue.async { [weak self] in
            guard let self else { return }
            let entries = self.logReader.recentEntries(withinLast: 3600)
            
            self.pairHandlingQueue.async { [weak self] in
                guard let self, !entries.isEmpty else { return }
                let sortedEntries = entries.sorted(by: { $0.date < $1.date })
                sortedEntries.forEach { self.updateNamedEntryCache(with: $0) }
                self.recentEntries = sortedEntries
                if let latestDate = sortedEntries.last?.date {
                    self.pruneRecentEntries(referenceDate: latestDate)
                }
                self.matchCurrentSessionFromBufferedEntries()
            }
        }
    }
    
    private func bootstrapCurrentPlaybackSession() {
        processQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            
            self.pairHandlingQueue.async { [weak self] in
                guard let self else { return }
                
                if let activation = self.logReader.recentActivations(withinLast: 3600).last {
                    NSLog("[Bootstrap] activation title=%@", activation.trackName)
                    self.beginSession(
                        track: MediaTrack(title: activation.trackName),
                        startedAt: activation.date,
                        historyLookback: 3600,
                        resolveSnapshot: true
                    )
                    return
                }
                
                guard let snapshot = self.snapshotReader.fetchCurrentTrack() else { return }
                NSLog("[Bootstrap] snapshot title=%@", snapshot.name ?? "nil")
                self.beginSession(
                    track: MediaTrack(snapshot: snapshot),
                    startedAt: Self.sessionStartDate(from: snapshot),
                    historyLookback: Self.historyLookbackSeconds(from: snapshot),
                    resolveSnapshot: false
                )
                
                if let directFormat = self.localFileFormatResolver.resolveLosslessFormat(for: snapshot),
                   let sessionID = self.currentSession?.id {
                    self.apply(format: directFormat, from: .localFile, to: sessionID)
                }
            }
        }
    }
    
    private func pruneRecentEntries(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-20)
        recentEntries.removeAll { $0.date < cutoff }
        if recentEntries.count > 80 {
            recentEntries.removeFirst(recentEntries.count - 80)
        }
    }
    
    private func updateNamedEntryCache(with entry: CMEntry) {
        guard let title = normalizedTrackField(entry.trackName) else { return }
        if let existing = latestNamedEntries[title], existing.date >= entry.date {
            return
        }
        latestNamedEntries[title] = entry
    }
    
    private func beginSession(
        track: MediaTrack,
        startedAt: Date,
        historyLookback: Int,
        resolveSnapshot: Bool
    ) {
        NSLog("[Session] start title=%@ startedAt=%.3f history=%d", track.title ?? "nil", startedAt.timeIntervalSince1970, historyLookback)
        if let currentSession, sameTrackIdentity(currentSession.track, track) {
            var updatedSession = currentSession
            if startedAt < currentSession.startedAt.addingTimeInterval(-1) {
                updatedSession.startedAt = startedAt
                NSLog("[Session] refined title=%@ startedAt=%.3f", track.title ?? "nil", startedAt.timeIntervalSince1970)
            }
            if isRicher(track: track, than: currentSession.track) {
                updatedSession.track = mergedTrack(currentSession.track, with: track)
                currentTrack = updatedSession.track
                NSLog("[Session] enriched title=%@", updatedSession.track.title ?? "nil")
            }
            self.currentSession = updatedSession
            if updatedSession.appliedFormat == nil {
                if resolveSnapshot {
                    resolveCurrentTrackSnapshot(for: updatedSession.id, track: updatedSession.track, attempt: 0)
                }
                primeHistoryForSession(sessionID: updatedSession.id, historyLookback: historyLookback)
                matchCurrentSessionFromBufferedEntries()
            }
            return
        }
        
        previousTrack = currentTrack
        currentTrack = track
        
        let session = PlaybackSession(
            id: UUID(),
            track: track,
            startedAt: startedAt
        )
        currentSession = session
        
        if resolveSnapshot {
            resolveCurrentTrackSnapshot(for: session.id, track: track, attempt: 0)
        }
        primeHistoryForSession(sessionID: session.id, historyLookback: historyLookback)
        matchCurrentSessionFromBufferedEntries()
    }
    
    private func sameTrackIdentity(_ lhs: MediaTrack, _ rhs: MediaTrack) -> Bool {
        guard let lhsTitle = normalizedTrackField(lhs.title),
              let rhsTitle = normalizedTrackField(rhs.title),
              lhsTitle == rhsTitle else { return false }
        let lhsArtist = normalizedTrackField(lhs.artist)
        let rhsArtist = normalizedTrackField(rhs.artist)
        if let lhsArtist, let rhsArtist {
            return lhsArtist == rhsArtist
        }
        return true
    }
    
    private func isRicher(track candidate: MediaTrack, than existing: MediaTrack) -> Bool {
        score(track: candidate) > score(track: existing)
    }
    
    private func score(track: MediaTrack) -> Int {
        [track.id, track.title, track.artist, track.album, track.trackNumber]
            .compactMap { $0 }
            .count
    }
    
    private func mergedTrack(_ lhs: MediaTrack, with rhs: MediaTrack) -> MediaTrack {
        MediaTrack(
            isMusicApp: lhs.isMusicApp || rhs.isMusicApp,
            id: lhs.id ?? rhs.id,
            title: lhs.title ?? rhs.title,
            album: lhs.album ?? rhs.album,
            artist: lhs.artist ?? rhs.artist,
            trackNumber: lhs.trackNumber ?? rhs.trackNumber
        )
    }
    
    private func resolveCurrentTrackSnapshot(for sessionID: UUID, track: MediaTrack, attempt: Int) {
        processQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshotReader.fetchCurrentTrack()
            
            self.pairHandlingQueue.async { [weak self] in
                guard let self, var session = self.currentSession, session.id == sessionID else { return }
                
                if let snapshot, !snapshot.roughlyMatches(track), attempt == 0 {
                    self.processQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.resolveCurrentTrackSnapshot(for: sessionID, track: track, attempt: 1)
                    }
                    return
                }
                
                session.snapshot = snapshot
                self.currentSession = session
                
                if let snapshot,
                   let directFormat = self.localFileFormatResolver.resolveLosslessFormat(for: snapshot) {
                    self.apply(format: directFormat, from: .localFile, to: sessionID)
                    return
                }
                
                self.matchCurrentSessionFromBufferedEntries()
            }
        }
    }
    
    private func primeHistoryForSession(sessionID: UUID, historyLookback: Int) {
        guard historyLookback > 20 else { return }
        
        processQueue.async { [weak self] in
            guard let self else { return }
            let historyEntries = self.logReader.recentEntries(withinLast: historyLookback)
            NSLog("[History] lookback=%d entries=%d", historyLookback, historyEntries.count)
            
            self.pairHandlingQueue.async { [weak self] in
                guard let self, let session = self.currentSession, session.id == sessionID else { return }
                guard let entry = self.bestLogEntry(for: session, entries: historyEntries) else {
                    NSLog("[History] no match title=%@", session.track.title ?? "nil")
                    return
                }
                
                NSLog("[History] match title=%@ rate=%d bits=%d", entry.trackName ?? "nil", entry.sampleRate, entry.bitDepth ?? -1)
                let format = AudioFormat(sampleRate: entry.sampleRate, bitDepth: entry.bitDepth)
                self.apply(format: format, from: .logStream, to: sessionID)
            }
        }
    }
    
    private func matchCurrentSessionFromBufferedEntries() {
        guard let session = currentSession else { return }
        guard session.appliedSource != .localFile else { return }
        guard let entry = bestLogEntry(for: session, entries: recentEntries) else { return }
        
        let format = AudioFormat(sampleRate: entry.sampleRate, bitDepth: entry.bitDepth)
        apply(format: format, from: .logStream, to: session.id)
    }
    
    private func bestLogEntry(for session: PlaybackSession, entries: [CMEntry]) -> CMEntry? {
        let windowStart = session.startedAt.addingTimeInterval(-5.0)
        let windowEnd = session.startedAt.addingTimeInterval(15.0)
        let candidates = entries.filter { $0.date >= windowStart && $0.date <= windowEnd }
        
        let targetTitle = normalizedTrackField(session.track.title ?? session.snapshot?.name)
        if let targetTitle {
            let titledMatches = entries.filter { normalizedTrackField($0.trackName) == targetTitle }
            let nearbyTitledMatches = titledMatches.filter { $0.date >= windowStart && $0.date <= windowEnd }
            if let best = nearbyTitledMatches.min(by: { titledMatchDistance(for: $0, anchor: session.startedAt) < titledMatchDistance(for: $1, anchor: session.startedAt) }) {
                return best
            }
            
            if let cachedMatch = latestNamedEntries[targetTitle] {
                return cachedMatch
            }
            
            // Apple Music can emit a track's format information well before it
            // becomes the active item. If we have an exact title match, prefer
            // the most recent pre-activation entry over leaving the previous
            // track's format in place.
            if let bestHistoricalMatch = titledMatches
                .filter({ $0.date < session.startedAt })
                .max(by: { $0.date < $1.date }) {
                return bestHistoricalMatch
            }
            
            if let nextTitledMatch = titledMatches
                .filter({ $0.date >= session.startedAt })
                .min(by: { $0.date < $1.date }) {
                return nextTitledMatch
            }
        }
        
        guard !candidates.isEmpty else { return nil }
        
        let anonymousMatches = candidates.filter { $0.trackName == nil && $0.date >= session.startedAt }
        if anonymousMatches.count == 1 {
            return anonymousMatches[0]
        }
        
        return anonymousMatches.sorted(by: { preferredMatch($0, over: $1, anchor: session.startedAt) }).first
    }
    
    private func preferredMatch(_ lhs: CMEntry, over rhs: CMEntry, anchor: Date) -> Bool {
        matchDistance(for: lhs, anchor: anchor) < matchDistance(for: rhs, anchor: anchor)
    }
    
    private func matchDistance(for entry: CMEntry, anchor: Date) -> TimeInterval {
        let delta = entry.date.timeIntervalSince(anchor)
        if delta >= 0 {
            return delta
        }
        return abs(delta) + 5
    }
    
    private func titledMatchDistance(for entry: CMEntry, anchor: Date) -> TimeInterval {
        abs(entry.date.timeIntervalSince(anchor))
    }
    
    private func apply(format: AudioFormat, from source: TrackResolutionSource, to sessionID: UUID) {
        guard var session = currentSession, session.id == sessionID else { return }
        if session.appliedFormat == format, session.appliedSource == source {
            return
        }
        
        session.appliedFormat = format
        session.appliedSource = source
        session.switchRetryCount = 0
        currentSession = session
        
        NSLog("[Apply] source=%@ rate=%d bits=%d", source.rawValue, format.sampleRate, format.bitDepth ?? -1)
        print("[Resolution] \(source.rawValue) -> \(format.sampleRate) / \(String(describing: format.bitDepth))")
        switchLatestSampleRate(format: format)
    }
    
    private func reapplyCurrentSessionFormatIfNeeded() {
        guard let session = currentSession else { return }
        guard !isSwitchingFormat else {
            needsReapplyAfterSwitch = true
            return
        }
        if let format = session.appliedFormat {
            switchLatestSampleRate(format: format)
        }
        else {
            matchCurrentSessionFromBufferedEntries()
        }
    }
    
    private func switchLatestSampleRate(format: AudioFormat) {
        guard let device = activeDevice(), device.isAlive else { return }
        
        let physicalFormats = getFormats(device: device) ?? []
        let currentPhysicalFormat = currentPhysicalFormat(for: device)
        let currentNominalSampleRate = device.nominalSampleRate
        let supportedSampleRates = availableSampleRates(for: device, physicalFormats: physicalFormats)
        guard let chosenSampleRate = preferredSampleRate(
            closestTo: Float64(format.sampleRate),
            supported: supportedSampleRates
        ) else {
            return
        }
        
        let chosenPhysicalFormat = selectPhysicalFormat(
            from: physicalFormats,
            sampleRate: chosenSampleRate,
            targetBitDepth: format.bitDepth,
            currentPhysicalFormat: currentPhysicalFormat
        )
        NSLog("[Switch] target=%d/%d chosen=%.0f/%d", format.sampleRate, format.bitDepth ?? -1, chosenSampleRate, chosenPhysicalFormat.map { Int($0.mBitsPerChannel) } ?? -1)
        
        if enableBitDepthDetection,
           format.bitDepth != nil,
           let chosenPhysicalFormat {
            let physicalFormatMatches = currentPhysicalFormat.map {
                sampleRatesEqual($0.mSampleRate, chosenPhysicalFormat.mSampleRate)
                    && $0.mBitsPerChannel == chosenPhysicalFormat.mBitsPerChannel
            } ?? false
            let nominalMatches = currentNominalSampleRate.map {
                sampleRatesEqual($0, chosenPhysicalFormat.mSampleRate)
            } ?? false
            
            if physicalFormatMatches && nominalMatches {
                updateWithObservedDeviceState(
                    device,
                    fallbackSampleRate: chosenPhysicalFormat.mSampleRate,
                    fallbackBitDepth: Int(chosenPhysicalFormat.mBitsPerChannel)
                )
                return
            }
            
            isSwitchingFormat = true
            needsReapplyAfterSwitch = false
            if !physicalFormatMatches {
                setFormats(device: device, format: chosenPhysicalFormat)
            }
            if !nominalMatches {
                device.setNominalSampleRate(chosenPhysicalFormat.mSampleRate)
            }
            finishSwitch(
                device,
                sessionID: currentSession?.id,
                expectedFormat: AudioFormat(
                    sampleRate: Int(chosenPhysicalFormat.mSampleRate.rounded()),
                    bitDepth: Int(chosenPhysicalFormat.mBitsPerChannel)
                ),
                fallbackSampleRate: chosenPhysicalFormat.mSampleRate,
                fallbackBitDepth: Int(chosenPhysicalFormat.mBitsPerChannel)
            )
        }
        else {
            let nominalMatches = currentNominalSampleRate.map {
                sampleRatesEqual($0, chosenSampleRate)
            } ?? false
            
            if !nominalMatches {
                isSwitchingFormat = true
                needsReapplyAfterSwitch = false
                device.setNominalSampleRate(chosenSampleRate)
            }
            let resolvedBitDepth = chosenPhysicalFormat.map { Int($0.mBitsPerChannel) }
            if nominalMatches {
                updateWithObservedDeviceState(
                    device,
                    fallbackSampleRate: chosenSampleRate,
                    fallbackBitDepth: resolvedBitDepth
                )
                return
            }
            finishSwitch(
                device,
                sessionID: currentSession?.id,
                expectedFormat: AudioFormat(
                    sampleRate: Int(chosenSampleRate.rounded()),
                    bitDepth: format.bitDepth
                ),
                fallbackSampleRate: chosenSampleRate,
                fallbackBitDepth: resolvedBitDepth
            )
        }
    }
    
    private func availableSampleRates(
        for device: AudioDevice,
        physicalFormats: [AudioStreamBasicDescription]
    ) -> [Float64] {
        let nominalSampleRates = device.nominalSampleRates ?? []
        let allSampleRates = nominalSampleRates + physicalFormats.map(\.mSampleRate)
        let uniqueSampleRates = Set(allSampleRates)
        return uniqueSampleRates.sorted()
    }
    
    private func preferredSampleRate(closestTo target: Float64, supported: [Float64]) -> Float64? {
        guard var nearest = supported.min(by: {
            abs($0 - target) < abs($1 - target)
        }) else {
            return nil
        }
        
        let halfRate = target / 2
        if Defaults.shared.userPreferSampleRateMultiples,
           !sampleRatesEqual(nearest, target),
           supported.contains(where: { sampleRatesEqual($0, halfRate) }) {
            nearest = halfRate
        }
        
        return nearest
    }
    
    private func selectPhysicalFormat(
        from formats: [AudioStreamBasicDescription],
        sampleRate: Float64,
        targetBitDepth: Int?,
        currentPhysicalFormat: AudioStreamBasicDescription?
    ) -> AudioStreamBasicDescription? {
        let sampleRateCandidates = formats.filter { sampleRatesEqual($0.mSampleRate, sampleRate) }
        guard !sampleRateCandidates.isEmpty else { return nil }
        
        if let currentPhysicalFormat,
           sampleRatesEqual(currentPhysicalFormat.mSampleRate, sampleRate),
           sampleRateCandidates.contains(where: {
               $0.mBitsPerChannel == currentPhysicalFormat.mBitsPerChannel
                   && sampleRatesEqual($0.mSampleRate, currentPhysicalFormat.mSampleRate)
           }) {
            if let targetBitDepth, targetBitDepth > 0 {
                let currentDistance = abs(Int(currentPhysicalFormat.mBitsPerChannel) - targetBitDepth)
                let bestDistance = sampleRateCandidates
                    .map { abs(Int($0.mBitsPerChannel) - targetBitDepth) }
                    .min() ?? currentDistance
                if currentDistance == bestDistance {
                    return currentPhysicalFormat
                }
            }
            else {
                return currentPhysicalFormat
            }
        }
        
        guard let targetBitDepth, targetBitDepth > 0 else {
            return sampleRateCandidates.max(by: {
                if $0.mBitsPerChannel != $1.mBitsPerChannel {
                    return $0.mBitsPerChannel < $1.mBitsPerChannel
                }
                return $0.mFormatFlags < $1.mFormatFlags
            })
        }
        
        return sampleRateCandidates.min(by: {
            let lhsDistance = abs(Int($0.mBitsPerChannel) - targetBitDepth)
            let rhsDistance = abs(Int($1.mBitsPerChannel) - targetBitDepth)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            if $0.mBitsPerChannel != $1.mBitsPerChannel {
                return $0.mBitsPerChannel < $1.mBitsPerChannel
            }
            return $0.mFormatFlags < $1.mFormatFlags
        })
    }
    
    private func sampleRatesEqual(_ lhs: Float64, _ rhs: Float64) -> Bool {
        abs(lhs - rhs) < 1
    }
    
    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        let streams = device.streams(scope: .output)
        return streams?.first?.availablePhysicalFormats?.compactMap(\.mFormat)
    }

    private func currentPhysicalFormat(for device: AudioDevice) -> AudioStreamBasicDescription? {
        device.streams(scope: .output)?.first?.physicalFormat
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }

    private func finishSwitch(
        _ device: AudioDevice,
        sessionID: UUID?,
        expectedFormat: AudioFormat,
        fallbackSampleRate: Float64,
        fallbackBitDepth: Int?
    ) {
        let deviceUID = device.uid
        pairHandlingQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            
            let observedDevice =
                deviceUID.flatMap { AudioDevice.lookup(by: $0) }
                ?? self.activeDevice()
            
            let observedState: (sampleRate: Float64, bitDepth: Int?)
            if let observedDevice {
                observedState = self.observedDeviceState(
                    observedDevice,
                    fallbackSampleRate: fallbackSampleRate,
                    fallbackBitDepth: fallbackBitDepth
                )
                self.updateSampleRate(
                    observedState.sampleRate,
                    bitDepth: observedState.bitDepth
                )
            }
            else {
                observedState = (
                    sampleRate: fallbackSampleRate,
                    bitDepth: fallbackBitDepth
                )
                self.updateSampleRate(fallbackSampleRate, bitDepth: fallbackBitDepth)
            }
            
            self.isSwitchingFormat = false
            
            let sampleRateMatches = self.sampleRatesEqual(
                observedState.sampleRate,
                Float64(expectedFormat.sampleRate)
            )
            let bitDepthMatches =
                !self.enableBitDepthDetection
                || expectedFormat.bitDepth == nil
                || observedState.bitDepth == expectedFormat.bitDepth
            
            if let sessionID,
               var session = self.currentSession,
               session.id == sessionID,
               session.appliedFormat == expectedFormat,
               (!sampleRateMatches || !bitDepthMatches),
               session.switchRetryCount < self.maxSwitchVerificationRetries {
                session.switchRetryCount += 1
                self.currentSession = session
                NSLog(
                    "[Verify] mismatch expected=%d/%d observed=%.0f/%d retry=%d",
                    expectedFormat.sampleRate,
                    expectedFormat.bitDepth ?? -1,
                    observedState.sampleRate,
                    observedState.bitDepth ?? -1,
                    session.switchRetryCount
                )
                self.pairHandlingQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.reapplyCurrentSessionFormatIfNeeded()
                }
                return
            }
            
            if let sessionID,
               let session = self.currentSession,
               session.id == sessionID,
               session.appliedFormat == expectedFormat,
               sampleRateMatches,
               bitDepthMatches,
               session.switchRetryCount > 0 {
                NSLog(
                    "[Verify] settled expected=%d/%d observed=%.0f/%d retries=%d",
                    expectedFormat.sampleRate,
                    expectedFormat.bitDepth ?? -1,
                    observedState.sampleRate,
                    observedState.bitDepth ?? -1,
                    session.switchRetryCount
                )
            }
            
            if self.needsReapplyAfterSwitch {
                self.needsReapplyAfterSwitch = false
                self.reapplyCurrentSessionFormatIfNeeded()
            }
        }
    }

    private func observedDeviceState(
        _ device: AudioDevice,
        fallbackSampleRate: Float64,
        fallbackBitDepth: Int?
    ) -> (sampleRate: Float64, bitDepth: Int?) {
        let observedPhysicalFormat = currentPhysicalFormat(for: device)
        return (
            sampleRate: device.nominalSampleRate
                ?? observedPhysicalFormat?.mSampleRate
                ?? fallbackSampleRate,
            bitDepth: observedPhysicalFormat.map { Int($0.mBitsPerChannel) } ?? fallbackBitDepth
        )
    }

    private func updateWithObservedDeviceState(
        _ device: AudioDevice,
        fallbackSampleRate: Float64,
        fallbackBitDepth: Int?
    ) {
        let observedState = observedDeviceState(
            device,
            fallbackSampleRate: fallbackSampleRate,
            fallbackBitDepth: fallbackBitDepth
        )
        updateSampleRate(observedState.sampleRate, bitDepth: observedState.bitDepth)
    }
    
    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        self.previousSampleRate = sampleRate
        self.previousBitDepth = bitDepth
        
        DispatchQueue.main.async { [self] in
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
            
            let delegate = AppDelegate.instance
            if enableBitDepthDetection {
                if let bitDepth {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / %d bit", readableSampleRate, bitDepth)
                }
                else {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / ? bit", readableSampleRate)
                }
            }
            else {
                delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
            }
        }
        
        self.runUserScript(sampleRate, bitDepth: bitDepth)
    }
    
    func runUserScript(_ sampleRate: Float64, bitDepth: Int?) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        var arguments = [argumentSampleRate]
        
        if let bitDepth {
            arguments.append(String(bitDepth))
        }
        
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
    
    private static func sessionStartDate(from trackInfo: TrackInfo) -> Date {
        guard let timestamp = trackInfo.payload.timestampEpochMicros else { return .now }
        let elapsedMicros = max(trackInfo.payload.elapsedTimeMicros ?? 0, 0)
        return Date(timeIntervalSince1970: (timestamp - elapsedMicros) / 1_000_000)
    }
    
    private static func historyLookbackSeconds(from trackInfo: TrackInfo) -> Int {
        let elapsed = max((trackInfo.payload.elapsedTimeMicros ?? 0) / 1_000_000, 0)
        return min(max(Int(elapsed.rounded(.up)) + 45, 180), 3600)
    }
    
    private static func sessionStartDate(from snapshot: MusicTrackSnapshot) -> Date {
        let elapsed = max(snapshot.playerPosition ?? 0, 0)
        return snapshot.fetchedAt.addingTimeInterval(-elapsed)
    }
    
    private static func historyLookbackSeconds(from snapshot: MusicTrackSnapshot) -> Int {
        let elapsed = max(snapshot.playerPosition ?? 0, 0)
        return min(max(Int(elapsed.rounded(.up)) + 45, 180), 3600)
    }
}
