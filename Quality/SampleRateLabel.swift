//
//  SampleRateLabel.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    var body: some View {
        Text(outputDevices.statusBarText(for: defaults.statusBarDisplayMode))
    }
}
