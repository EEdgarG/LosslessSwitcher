//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import AppKit
import Combine
import Foundation
import SimplyCoreAudio
import CoreAudioTypes
import MediaRemoteAdapter
import OrderedCollections

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private let logReader = LogReader()
    private var entryStreamReceiver: AnyCancellable?
    private var lastTrackChangeTime: Date?
    
    private var collection: OrderedDictionary<String, InfoPair> = [:]
    private var currentTrackPair: DatedPair<MediaTrack>?
    private var updateRequester = PassthroughSubject<Void, Never>()
    private var updateRequesterReceiver: AnyCancellable?
    
    private var pairHandlingQueue = DispatchQueue(label: "phq", qos: .userInteractive)
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerActive = false
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        self.logReader.spawnProcessIfNeeded()
        
        // WIP: This code is dizzying to work with...
        entryStreamReceiver = logReader.entryStream.receive(on: pairHandlingQueue).sink { [weak self] entry in
            //print("ESR", self.lastTrackChangeTime, self.currentTrack, entry.date, entry.trackName, entry.sampleRate)
            
            let key = entry.trackName ?? UUID().uuidString
            
            // The AppleScript path keeps every line: it only uses them to look up bit depth.
            if self?.usesAppleScriptRate == false, entry.trackName == nil, let lastKey = self?.collection.keys.last, let lastDate = self?.collection[lastKey]?.format?.date {
                if abs(lastDate.timeIntervalSince1970 - entry.date.timeIntervalSince1970) < 1 {
                    return
                }
            }
            
            let format = DatedPair(date: entry.date, object: AudioFormat(sampleRate: entry.sampleRate, bitDepth: entry.bitDepth))
            if let pair = self?.collection[key] {
                pair.format = format
            }
            else {
                self?.collection[key] = InfoPair(format: format)
            }
            
            self?.updateRequester.send()
        }
        
        updateRequesterReceiver = updateRequester
            .throttle(for: 0.2, scheduler: DispatchQueue.global(), latest: true)
            .receive(on: pairHandlingQueue)
            .sink { [weak self] in
                // With the AppleScript path on, the log only supplies bit depth; it doesn't switch.
                guard self?.usesAppleScriptRate == false else { return }
                guard let collection = self?.collection, let currentTrackPair = self?.currentTrackPair else { return }
                print(collection)
                var limit = 0
                for (_, value) in collection.reversed() {
                    guard limit < 5 else { return }
                    defer {
                        limit += 1
                    }
                    
                    if let track = value.track?.object, let current = self?.currentTrack, track == current {
                        print("URR TRACK YES")
                        if let format = value.format?.object {
                            print("URR FORMAT YES")
                            self?.switchLatestSampleRate(format: format)
                            return
                        }
                    }
                    
//                    let trackValue = value.track
//                    let format = value.format
//                    if let title = currentTrackPair.object.title {
//                        
//                        return
//                    }
                }
        }
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })
        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        entryStreamReceiver?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.timerCalls += 1
                if self.timerCalls >= 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
//                    self.processQueue.async {
//                        self.switchLatestSampleRate()
//                    }
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                print("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
//            let musicLogs = try Console.getRecentEntries(type: .music)
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
//            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            
//            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
//            if enableBitDepthDetection {
                allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
//            }
//            else {
//                allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
//            }

//            allStats.sort(by: {$0.priority > $1.priority})
            print("[getAllStats] \(allStats)")
        }
        catch {
            print("[getAllStats, error] \(error)")
        }
        
        return allStats
    }
    
    func switchLatestSampleRate(format: AudioFormat) {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        if let supported = defaultDevice?.nominalSampleRates {
            let sampleRate = Float64(format.sampleRate)
            let bitDepth = Int32(format.bitDepth ?? 32)
            
//            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
//                print("same track, prev sample rate is higher")
//                return
//            }
//            
//            if sampleRate == 48000 && !recursion {
//                processQueue.asyncAfter(deadline: .now() + 1) {
//                    self.switchLatestSampleRate(recursion: true)
//                }
//            }
            
            let formats = self.getFormats(device: defaultDevice!)!
            
            // https://stackoverflow.com/a/65060134
            var nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })
            
            let nearestBitDepth = formats.min(by: {
                abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
            })
            
            if Defaults.shared.userPreferSampleRateMultiples,
               let nearestSampleRate = nearest,
               nearestSampleRate != sampleRate, supported.contains(sampleRate / 2) {
                nearest = sampleRate / 2
            }
            
            let nearestFormat = formats.filter({
                $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
            })
            
            print("NEAREST FORMAT \(nearestFormat)")
            
            if let suitableFormat = nearestFormat.first {
                if enableBitDepthDetection {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                }
                else if suitableFormat.mSampleRate != previousSampleRate { // bit depth disabled
                    defaultDevice?.setNominalSampleRate(suitableFormat.mSampleRate)
                }
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(suitableFormat.mBitsPerChannel))
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                    self.trackAndBitDepth[currentTrack] = Int(suitableFormat.mBitsPerChannel)
                }
            }

//            if let nearest = nearest {
//                let nearestSampleRate = nearest.element
//                if nearestSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(nearestSampleRate)
//                    self.updateSampleRate(nearestSampleRate)
//                    if let currentTrack = currentTrack {
//                        self.trackAndSample[currentTrack] = nearestSampleRate
//                    }
//                }
//            }
        }
//        else if !recursion {
//            processQueue.asyncAfter(deadline: .now() + 1) {
//                self.switchLatestSampleRate(recursion: true)
//            }
//        }
        else {
//                print("cache \(self.trackAndSample)")
            if self.currentTrack == self.previousTrack {
                print("same track, ignore cache")
                return
            }
//            if let currentTrack = currentTrack, let cachedSampleRate = trackAndSample[currentTrack] {
//                print("using cached data")
//                if cachedSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(cachedSampleRate)
//                    self.updateSampleRate(cachedSampleRate)
//                }
//            }
        }

    }
    
    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
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
                if let bitDepth = bitDepth {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / %d bit", readableSampleRate, bitDepth)
                } else {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / ? bit", readableSampleRate)
                }
            } else {
                delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
            }
        }
        self.runUserScript(sampleRate, bitDepth: bitDepth)
    }
    
    func runUserScript(_ sampleRate: Float64, bitDepth: Int?) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        var arguments = [argumentSampleRate]
        
        // Add bit depth as second argument if available
        if let bitDepth = bitDepth {
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
    
    func trackDidChange(_ newTrack: TrackInfo) {
        let mt = MediaTrack(trackInfo: newTrack)
        
        guard previousTrack != mt else { return }
        // MediaRemote can repeat the same track; only a real change restarts the AppleScript poll.
        let isNewTrack = currentTrack != mt
        self.previousTrack = self.currentTrack
        self.currentTrack = mt

        pairHandlingQueue.async { [weak self] in
            let now = Date.now
            let pair = DatedPair(date: now, object: mt)
            self?.currentTrackPair = pair
            
            let key = mt.title ?? UUID().uuidString
            if let collectionPair = self?.collection[key] {
                collectionPair.track = pair
            }
            else if let lastKey = self?.collection.keys.last, self?.collection[lastKey]?.track == nil, UUID(uuidString: lastKey) != nil {
                self?.collection[lastKey]?.track = pair
            }
            else {
                self?.collection[key] = .init(track: pair)
            }
            self?.updateRequester.send()
        }
        
        
        if usesAppleScriptRate, isNewTrack {
            appleScriptGeneration += 1
            pollMusic(expectedTitle: mt.title, generation: appleScriptGeneration, attempt: 0, start: Date())
        }
        
//        if self.previousTrack != self.currentTrack {
//            self.renewTimer()
//        }
//        processQueue.async { [unowned self] in
//            self.switchLatestSampleRate()
//        }
        lastTrackChangeTime = Date()
    }
    
    // MARK: - Prototype for #159: sample rate from AppleScript
    
    private enum MusicReading {
        case notRunning
        case denied
        case failed(code: Int)
        case playing(name: String?, sampleRate: Int?)
    }
    
    private var appleScriptDenied = false
    private var appleScriptGeneration = 0
    private let musicPollInterval: TimeInterval = 0.2
    private let musicMaxPolls = 15
    
    private lazy var nowPlayingScript: NSAppleScript? = {
        let source = "tell application \"Music\" to return {name of current track, sample rate of current track}"
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        if let error {
            print("[AS159] compile error \(error)")
        }
        return script
    }()
    
    private static let logClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    var usesAppleScriptRate: Bool {
        return Defaults.shared.useAppleScriptSampleRate && !appleScriptDenied
    }
    
    private func readMusic() -> MusicReading {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !running.isEmpty else { return .notRunning }
        guard let script = nowPlayingScript else { return .failed(code: 0) }
        
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            return code == -1743 ? .denied : .failed(code: code)
        }
        
        let name = result.atIndex(1)?.stringValue
        let sampleRate = result.atIndex(2)?.stringValue.flatMap { Double($0) }.map { Int($0) }
        return .playing(name: name, sampleRate: sampleRate)
    }
    
    private func pollMusic(expectedTitle: String?, generation: Int, attempt: Int, start: Date) {
        guard generation == appleScriptGeneration else { return }
        
        let reading = readMusic()
        let elapsed = Date().timeIntervalSince(start)
        print("[AS159] \(OutputDevices.logClock.string(from: Date())) +\(String(format: "%.2f", elapsed))s poll \(attempt) expected=\(expectedTitle ?? "nil") reading=\(reading)")
        
        switch reading {
        case .denied:
            appleScriptDenied = true
            print("[AS159] Apple Events permission denied, falling back to log pairing")
            updateRequester.send()
            return
        case .playing(let name, let sampleRate?) where name == expectedTitle:
            applyMusicSampleRate(sampleRate, elapsed: elapsed)
            return
        default:
            break
        }
        
        guard attempt + 1 < musicMaxPolls else {
            print("[AS159] gave up after \(musicMaxPolls) polls, rate left unchanged")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + musicPollInterval) { [weak self] in
            self?.pollMusic(expectedTitle: expectedTitle, generation: generation, attempt: attempt + 1, start: start)
        }
    }
    
    private func applyMusicSampleRate(_ sampleRate: Int, elapsed: TimeInterval) {
        pairHandlingQueue.async { [weak self] in
            guard let self else { return }
            let match = self.collection.values.reversed().first { $0.format?.object.sampleRate == sampleRate }
            let bitDepth = match?.format?.object.bitDepth
            print("[AS159] \(OutputDevices.logClock.string(from: Date())) apply \(sampleRate) Hz / \(bitDepth.map(String.init) ?? "?") bit (bit depth from log: \(match != nil)) after +\(String(format: "%.2f", elapsed))s")
            self.switchLatestSampleRate(format: AudioFormat(sampleRate: sampleRate, bitDepth: bitDepth))
        }
    }
}
