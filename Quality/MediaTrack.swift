//
//  MediaTrack.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Foundation
import PrivateMediaRemote
import MediaRemoteAdapter

struct MediaTrack: Equatable, Hashable {
    
    let isMusicApp: Bool
    let id: String?
    
    let title: String?
    let album: String?
    let artist: String?
    let trackNumber: String?
    
    init(
        isMusicApp: Bool,
        id: String?,
        title: String?,
        album: String?,
        artist: String?,
        trackNumber: String?
    ) {
        self.isMusicApp = isMusicApp
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.trackNumber = trackNumber
    }
    
    init(mediaRemote info: [String : Any]) {
        self.init(
            isMusicApp: info[kMRMediaRemoteNowPlayingInfoIsMusicApp] as? Bool ?? false,
            id: info[kMRMediaRemoteNowPlayingInfoUniqueIdentifier] as? String,
            title: info[kMRMediaRemoteNowPlayingInfoTitle] as? String,
            album: info[kMRMediaRemoteNowPlayingInfoAlbum] as? String,
            artist: info[kMRMediaRemoteNowPlayingInfoArtist] as? String,
            trackNumber: info[kMRMediaRemoteNowPlayingInfoTrackNumber] as? String
        )
    }
    
    init(trackInfo: TrackInfo) {
        let payload = trackInfo.payload
        self.init(
            isMusicApp: true,
            id: payload.uniqueIdentifier,
            title: payload.title,
            album: payload.album,
            artist: payload.artist,
            trackNumber: nil
        )
    }
    
    init(snapshot: MusicTrackSnapshot) {
        self.init(
            isMusicApp: true,
            id: snapshot.persistentID,
            title: snapshot.name,
            album: snapshot.album,
            artist: snapshot.artist,
            trackNumber: nil
        )
    }
    
    init(title: String) {
        self.init(
            isMusicApp: true,
            id: nil,
            title: title,
            album: nil,
            artist: nil,
            trackNumber: nil
        )
    }
}
