//
//  LogReader.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/3/26.
//

import Foundation
import Combine
import Sweep

struct TrackActivation {
    let date: Date
    let trackName: String
}

class LogReader {
    
    let entryStream = PassthroughSubject<CMEntry, Never>()
    let activationStream = PassthroughSubject<TrackActivation, Never>()
    
    private var process: Process?
    private let dateFormatter: DateFormatter
    private var dataBuffer = Data()
    
    init() {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = .autoupdatingCurrent
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.dateFormatter = dateFormatter
    }
    
    func spawnProcessIfNeeded() {
        guard process == nil else { return }
        self.spawnProcess()
    }
    
    func recentEntries(withinLast seconds: Int) -> [CMEntry] {
        recentLogLines(withinLast: seconds)
            .compactMap { self.parseLine($0) }
    }
    
    func recentActivations(withinLast seconds: Int) -> [TrackActivation] {
        recentLogLines(withinLast: seconds)
            .compactMap { self.parseActivation($0) }
    }
    
    private func recentLogLines(withinLast seconds: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--last",
            "\(seconds)s",
            "--style",
            "compact",
            "--predicate",
            "process = \"Music\" AND category=\"ampplay\""
        ]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        
        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }
        catch {
            print("[LogReader recentLogLines] \(error)")
            return []
        }
    }
    
    private func spawnProcess() {
        let process = Process()
        self.process = process
        
        process.executableURL = URL(filePath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style",
            "compact",
            "--no-backtrace",
            "--predicate",
            "process = \"Music\" AND category=\"ampplay\""
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.terminationHandler = { [weak self] _ in
            self?.process = nil
        }
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            
            self?.append(data)
        }
        
        do {
            try process.run()
        }
        catch {
            print("ProcessErr \(error)")
        }
    }
    
    func stop() {
        process?.terminate()
        process = nil
    }
    
    private func append(_ data: Data) {
        dataBuffer.append(data)
        let newline = Data([0x0A])
        
        while let range = dataBuffer.firstRange(of: newline) {
            let lineData = dataBuffer.subdata(in: 0..<range.lowerBound)
            dataBuffer.removeSubrange(0..<range.upperBound)
            
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else {
                continue
            }
            
            processLine(line)
        }
    }
    
    private func processLine(_ line: String) {
        if let activation = parseActivation(line) {
            activationStream.send(activation)
        }
        if let entry = parseLine(line) {
            entryStream.send(entry)
        }
    }
    
    private func parseLine(_ line: String) -> CMEntry? {
        guard let date = parseDate(from: line) else { return nil }
        guard let messageContentSubstring = line.firstSubstring(between: "[com.apple.Music:ampplay] play> cm>> " , and: .end) else { return nil }
        let message = String(messageContentSubstring)
        
        let split = message.split(separator: ",")
        var trackName: String?
        var isLossless: Bool?
        var bitDepth: Int?
        var sampleRate: Int?
        
        for element in split {
            
            // <private> in default circumstances
            if trackName == nil, element.hasPrefix("mediaFormatinfo") {
                guard let substring = element.firstSubstring(between: "\'", and: "\'") else { continue }
                trackName = String(substring)
                continue
            }
            
            // notes: there is a field that may be "lossless", "high res lossless" and "stereo (lossy)"
            
            if isLossless == nil, element.hasPrefix(" sdFormatID") {
                guard let substring = element.firstSubstring(between: "= ", and: .end) else { continue }
                isLossless = substring == "alac"
                continue
            }
            
            if bitDepth == nil, element.hasPrefix(" sdBitDepth") {
                guard let substring = element.firstSubstring(between: "= ", and: " bit") else { continue }
                bitDepth = Int(substring)
            }
            
            if sampleRate == nil, element.hasPrefix(" asbdSampleRate") {
                guard let substring = element.firstSubstring(between: "= ", and: " kHz") else { continue }
                let string = String(substring)
                guard let double = Double(string) else { continue }
                sampleRate = Int(double * 1000)
                continue
            }
            
        }
        
        // this requires an external profile to read this info
        // might be helpful to prevent the early track sample rate switch issue.
        // https://eclecticlight.co/2023/03/08/removing-privacy-censorship-from-the-log/
        if let tn = trackName, tn == "<private>" {
            trackName = nil
        }
        
        guard let isLossless, let sampleRate else { return nil }
        
        guard isLossless else { return nil }
        
        return CMEntry(date: date, trackName: trackName, bitDepth: bitDepth, sampleRate: sampleRate)
    }
    
    private func parseActivation(_ line: String) -> TrackActivation? {
        guard let date = parseDate(from: line) else { return nil }
        guard let nameSubstring = line.firstSubstring(between: "_willBecomeActivePlayerItem ", and: .end) else { return nil }
        let rawName = String(nameSubstring)
        guard let titleStart = rawName.range(of: ") ")?.upperBound else { return nil }
        let title = rawName[titleStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return TrackActivation(date: date, trackName: title)
    }
    
    private func parseDate(from line: String) -> Date? {
        guard let dateSubstring = line.firstSubstring(between: .start, and: " Df ") else { return nil }
        return dateFormatter.date(from: String(dateSubstring))
    }
}
