//
//  MediaRemoteController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
//import Combine
//import PrivateMediaRemote
import MediaRemoteAdapter

fileprivate let kMusicAppBundle = "com.apple.Music"

class MediaRemoteController {
    
    private let controller: MediaController
    
    init(outputDevices: OutputDevices) {
        
        let controller = MediaController()
        self.controller = controller
        controller.startListening()
        
        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            print("track \(trackInfo.payload.uniqueIdentifier) \(trackInfo.payload.title ?? "nil")")
            // The AppleScript path polls until Music reports the new track, so it doesn't
            // need the 1 s head start the log pairing relies on.
            let delay: TimeInterval = (outputDevices?.usesAppleScriptRate ?? false) ? 0 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let outputDevices else { return }
                outputDevices.trackDidChange(trackInfo)
            }
        }
        
    }
    
    deinit {
        controller.stopListening()
    }
    
}
