//
//  AudioFormat.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/3/26.
//

import Foundation

struct AudioFormat: Equatable {
    let sampleRate: Int
    let bitDepth: Int?
    let bitRate: Int?
}
