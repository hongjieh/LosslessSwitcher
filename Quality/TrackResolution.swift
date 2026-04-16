//
//  TrackResolution.swift
//  LosslessSwitcher
//
//  Created by Codex on 15/4/26.
//

import AudioToolbox
import Foundation

enum TrackResolutionSource: String {
    case localFile
    case logStream
}

enum LogMatchingMode: String {
    case fallback
    case profileBacked
}

struct MusicTrackSnapshot {
    let fetchedAt: Date
    let trackClassName: String?
    let name: String?
    let artist: String?
    let album: String?
    let persistentID: String?
    let kind: String?
    let playerPosition: TimeInterval?
    let sampleRate: Int?
    let bitRate: Int?
    let locationPath: String?
    
    var isLocalFileTrack: Bool {
        guard let locationPath else { return false }
        return !locationPath.isEmpty
    }
    
    var isLikelyLosslessLocalTrack: Bool {
        guard isLocalFileTrack else { return false }
        let normalizedKind = normalizedTrackField(kind) ?? ""
        return normalizedKind.contains("lossless")
            || normalizedKind.contains("wav")
            || normalizedKind.contains("wave")
            || normalizedKind.contains("aiff")
            || normalizedKind.contains("flac")
    }
    
    func roughlyMatches(_ track: MediaTrack) -> Bool {
        let comparisons = [
            compareTrackField(name, track.title),
            compareTrackField(artist, track.artist),
            compareTrackField(album, track.album)
        ]
        
        return comparisons.allSatisfy { $0 != false }
    }
}

struct PlaybackSession {
    let id: UUID
    var track: MediaTrack
    var startedAt: Date
    var snapshot: MusicTrackSnapshot?
    var appliedFormat: AudioFormat?
    var appliedSource: TrackResolutionSource?
    var switchRetryCount = 0
}

final class LogPrivacyProfileDetector {
    private static let knownProfileIdentifiers = [
        "co.eclecticlight.profile.logprivate"
    ]
    
    func detectMatchingMode() -> LogMatchingMode {
        if hasKnownPrivateDataProfile() || hasPrivateDataLoggingPayload() {
            return .profileBacked
        }
        return .fallback
    }
    
    private func hasKnownPrivateDataProfile() -> Bool {
        guard let output = runCommand(
            executablePath: "/usr/bin/profiles",
            arguments: ["list"]
        ) else {
            return false
        }
        
        if Self.knownProfileIdentifiers.contains(where: output.contains) {
            return true
        }
        
        return output.localizedCaseInsensitiveContains("Enable Log Private Data")
    }
    
    private func hasPrivateDataLoggingPayload() -> Bool {
        guard let output = runCommand(
            executablePath: "/usr/sbin/system_profiler",
            arguments: ["SPConfigurationProfileDataType", "-json"]
        ),
        let data = output.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return false
        }
        
        return containsPrivateDataLoggingPayload(in: json)
    }
    
    private func runCommand(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }
        catch {
            print("[LogPrivacyProfileDetector] \(error)")
            return nil
        }
    }
    
    private func containsPrivateDataLoggingPayload(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let payloadName = dictionary["_name"] as? String,
               payloadName == "com.apple.system.logging",
               let payloadData = dictionary["spconfigprofile_payload_data"] as? String,
               payloadData.contains("Enable-Private-Data"),
               payloadData.contains("= 1") {
                return true
            }
            
            return dictionary.values.contains(where: containsPrivateDataLoggingPayload(in:))
        }
        
        if let array = value as? [Any] {
            return array.contains(where: containsPrivateDataLoggingPayload(in:))
        }
        
        return false
    }
}

final class MusicTrackSnapshotReader {
    private let separator = String(UnicodeScalar(30))
    
    func fetchCurrentTrack() -> MusicTrackSnapshot? {
        var error: NSDictionary?
        let script = """
        on optionalText(theValue)
            if theValue is missing value then return ""
            return theValue as text
        end optionalText

        tell application "Music"
            try
                if player state is stopped then return ""
            on error
                return ""
            end try
            
            try
                set theTrack to current track
            on error
                return ""
            end try
            
            set trackClass to my optionalText(class of theTrack)
            set trackName to my optionalText(name of theTrack)
            set trackArtist to my optionalText(artist of theTrack)
            set trackAlbum to my optionalText(album of theTrack)
            set trackPersistentID to my optionalText(persistent ID of theTrack)
            set trackKind to my optionalText(kind of theTrack)
            set trackPlayerPosition to (player position) as text
            
            try
                set trackSampleRate to (sample rate of theTrack) as text
            on error
                set trackSampleRate to ""
            end try
            
            try
                set trackBitRate to (bit rate of theTrack) as text
            on error
                set trackBitRate to ""
            end try
            
            try
                set trackLocation to POSIX path of ((location of theTrack) as alias)
            on error
                set trackLocation to ""
            end try
            
            set oldTIDs to AppleScript's text item delimiters
            set AppleScript's text item delimiters to (ASCII character 30)
            set payload to {trackClass, trackName, trackArtist, trackAlbum, trackPersistentID, trackKind, trackPlayerPosition, trackSampleRate, trackBitRate, trackLocation} as text
            set AppleScript's text item delimiters to oldTIDs
            return payload
        end tell
        """
        
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        guard let raw = scriptObject.executeAndReturnError(&error).stringValue else {
            if let error {
                print("[MusicTrackSnapshotReader] \(error)")
            }
            return nil
        }
        
        if let error {
            print("[MusicTrackSnapshotReader] \(error)")
        }
        
        guard !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: separator)
        guard parts.count == 10 else {
            print("[MusicTrackSnapshotReader] Unexpected payload: \(raw)")
            return nil
        }
        
        return MusicTrackSnapshot(
            fetchedAt: .now,
            trackClassName: blankToNil(parts[0]),
            name: blankToNil(parts[1]),
            artist: blankToNil(parts[2]),
            album: blankToNil(parts[3]),
            persistentID: blankToNil(parts[4]),
            kind: blankToNil(parts[5]),
            playerPosition: TimeInterval(parts[6]),
            sampleRate: Int(parts[7]),
            bitRate: Int(parts[8]),
            locationPath: blankToNil(parts[9])
        )
    }
}

final class LocalFileFormatResolver {
    func resolveFormat(for snapshot: MusicTrackSnapshot) -> AudioFormat? {
        guard snapshot.isLocalFileTrack else { return nil }
        
        if !snapshot.isLikelyLosslessLocalTrack {
            guard let sampleRate = snapshot.sampleRate else { return nil }
            return AudioFormat(
                sampleRate: sampleRate,
                bitDepth: nil,
                bitRate: snapshot.bitRate
            )
        }
        
        guard let locationPath = snapshot.locationPath else { return nil }
        
        do {
            let metadata = try readDataFormat(at: locationPath)
            let resolvedSampleRate = Int(metadata.sampleRate.rounded())
            let resolvedBitDepth = metadata.bitDepth > 0 ? Int(metadata.bitDepth) : nil
            return AudioFormat(
                sampleRate: resolvedSampleRate,
                bitDepth: resolvedBitDepth,
                bitRate: snapshot.bitRate
            )
        }
        catch {
            print("[LocalFileFormatResolver] \(error)")
            guard let sampleRate = snapshot.sampleRate else { return nil }
            return AudioFormat(
                sampleRate: sampleRate,
                bitDepth: nil,
                bitRate: snapshot.bitRate
            )
        }
    }
    
    private func readDataFormat(at path: String) throws -> (sampleRate: Double, bitDepth: UInt32) {
        let url = URL(fileURLWithPath: path) as CFURL
        var fileID: AudioFileID?
        try check(AudioFileOpenURL(url, .readPermission, 0, &fileID))
        guard let fileID else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(paramErr))
        }
        defer {
            AudioFileClose(fileID)
        }
        
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &size, &asbd))
        return (sampleRate: asbd.mSampleRate, bitDepth: asbd.mBitsPerChannel)
    }
    
    private func check(_ status: OSStatus) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

func normalizedTrackField(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalizedPunctuation = value
        .replacingOccurrences(of: "\u{2018}", with: "'")
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: "\u{201C}", with: "\"")
        .replacingOccurrences(of: "\u{201D}", with: "\"")
        .replacingOccurrences(of: "\u{2010}", with: "-")
        .replacingOccurrences(of: "\u{2011}", with: "-")
        .replacingOccurrences(of: "\u{2012}", with: "-")
        .replacingOccurrences(of: "\u{2013}", with: "-")
        .replacingOccurrences(of: "\u{2014}", with: "-")
        .replacingOccurrences(of: "\u{2212}", with: "-")
        .replacingOccurrences(of: "\u{2026}", with: "...")
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: "\u{3000}", with: " ")
    
    let halfWidth = normalizedPunctuation.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? normalizedPunctuation
    let collapsedWhitespace = halfWidth.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    let trimmed = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
}

private func blankToNil(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func compareTrackField(_ lhs: String?, _ rhs: String?) -> Bool? {
    guard let lhs = normalizedTrackField(lhs), let rhs = normalizedTrackField(rhs) else { return nil }
    return lhs == rhs
}
