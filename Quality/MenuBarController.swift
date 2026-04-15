//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import Observation
import SwiftUI

@Observable
class MenuBarController {
    static let shared = MenuBarController()
    
    @ObservationIgnored
    var outputDevices: OutputDevices!
    
    @ObservationIgnored
    private var mrController: MediaRemoteController!
    
    private init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
    }
}
