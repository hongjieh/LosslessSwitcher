//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

enum StatusBarDisplayMode: String, CaseIterable, Identifiable {
    case sourceAndOutput
    case sourceOnly
    case outputOnly
    
    var id: String { rawValue }
    
    var menuTitle: String {
        switch self {
        case .sourceAndOutput:
            return "Source -> Output"
        case .sourceOnly:
            return "Source Only"
        case .outputOnly:
            return "Output Only"
        }
    }
}

class Defaults: ObservableObject {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.vincent-neo.LosslessSwitcher-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.vincent-neo.LosslessSwitcher-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.vincent-neo.LosslessSwitcher-Key-BitDepthDetection"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kStatusBarDisplayMode = "StatusBarDisplayMode"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferSampleRateMultiples : false,
            kStatusBarDisplayMode : StatusBarDisplayMode.outputOnly.rawValue
        ])
        
        self.shellScriptPath = UserDefaults.standard.string(forKey: kShellScriptPath)
        self.userPreferIconStatusBarItem = UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
        self.userPreferSampleRateMultiples = UserDefaults.standard.bool(forKey: kUserPreferSampleRateMultiples)
        self.statusBarDisplayMode = StatusBarDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: kStatusBarDisplayMode) ?? ""
        ) ?? .outputOnly
    }
    
    @Published var userPreferSampleRateMultiples: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferSampleRateMultiples)
        }
    }
    
    @Published var userPreferIconStatusBarItem: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferIconStatusBarItem)
        }
    }
    
    @Published var statusBarDisplayMode: StatusBarDisplayMode {
        willSet {
            UserDefaults.standard.set(newValue.rawValue, forKey: kStatusBarDisplayMode)
        }
    }
    
    var selectedDeviceUID: String? {
        get {
            return UserDefaults.standard.string(forKey: kSelectedDeviceUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kSelectedDeviceUID)
        }
    }
    
    @Published var shellScriptPath: String? {
        willSet {
            UserDefaults.standard.setValue(newValue, forKey: kShellScriptPath)
        }
    }
    
    @Published var userPreferBitDepthDetection: Bool
    
    
    @MainActor func setPreferBitDepthDetection(newValue: Bool) {
        UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDetection)
        self.userPreferBitDepthDetection = newValue
    }
    
    @MainActor func setShellScriptPath(newValue: String?) {
        self.shellScriptPath = newValue
    }
    
    @MainActor func setPreferSampleRateMultiple(newValue: Bool) {
        self.userPreferSampleRateMultiples = newValue
    }
    
    @MainActor func setStatusBarDisplayMode(newValue: StatusBarDisplayMode) {
        self.statusBarDisplayMode = newValue
    }

    var statusBarItemTitle: String {
        let title = self.userPreferIconStatusBarItem ? "Show Sample Rate" : "Show Icon"
        return title
    }
}
