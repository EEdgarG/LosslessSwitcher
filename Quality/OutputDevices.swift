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
            self?.recordMusicFormatLine(format)
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
        
        observeMusicTermination()

    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        entryStreamReceiver?.cancel()
        if let musicTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(musicTerminationObserver)
        }
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
        
        
        if Defaults.shared.useAppleScriptSampleRate, OutputDevices.musicPermission == .undetermined {
            // The last prompt got no answer: ask again now that a track is playing.
            OutputDevices.musicPermission = .unknown
        }
        if wantsAppleScriptRate, isNewTrack {
            startMusicPoll(expectedTitle: mt.title)
        }
        
//        if self.previousTrack != self.currentTrack {
//            self.renewTimer()
//        }
//        processQueue.async { [unowned self] in
//            self.switchLatestSampleRate()
//        }
        lastTrackChangeTime = Date()
    }
    
    // MARK: - #159: sample rate from Music via AppleScript
    
    private enum MusicReading {
        case notRunning
        case denied
        case failed(code: Int)
        case playing(name: String?, sampleRate: Int?)
    }
    
    /// Whether macOS lets this app send Apple events to Music.
    /// - unknown: not asked yet in this launch.
    /// - checking: the question is in flight on `musicPermissionQueue`. The prompt can stay open
    ///   for as long as the user leaves it (measured: 9 minutes, it doesn't expire), so the log
    ///   pairing keeps switching meanwhile.
    /// - undetermined: the question ended without a yes or no (e.g. -600, Music not running);
    ///   the log path covers the current track, and the next track change asks again.
    private enum MusicPermission {
        case unknown, checking, granted, denied, undetermined
    }
    
    // AppDelegate and MenuBarController each create an OutputDevices, so the permission state
    // is shared: the user gets one prompt, and both instances learn the answer.
    // It's read from the main thread, pairHandlingQueue and MediaRemote's callback, hence the lock.
    private static let musicPermissionLock = NSLock()
    private static var _musicPermission = MusicPermission.unknown
    private static var musicPermission: MusicPermission {
        get { musicPermissionLock.withLock { _musicPermission } }
        set { musicPermissionLock.withLock { _musicPermission = newValue } }
    }
    /// Callbacks waiting for the answer to the question in flight. Main thread only.
    private static var musicPermissionWaiters: [(MusicPermission) -> Void] = []
    /// The permission question can block for as long as the macOS prompt stays open
    /// (up to 2 minutes), so it never runs on the main thread.
    private static let musicPermissionQueue = DispatchQueue(label: "musicPermission", qos: .userInitiated)
    
    private var appleScriptGeneration = 0
    private let musicPollInterval: TimeInterval = 0.2
    private let musicMaxPolls = 15
    
    /// Recent lossless `ampplay` lines, oldest first. Only pairHandlingQueue touches them.
    /// The AppleScript path uses them for bit depth only.
    private var musicFormatLines: [DatedPair<AudioFormat>] = []
    private let musicFormatLinesLimit = 32
    /// Date of the last line whose bit depth was used, so the next track starts after it.
    private var lastUsedFormatLineDate: Date?
    private var musicTerminationObserver: NSObjectProtocol?
    
    // `with timeout` bounds a busy or hung Music to 2 s instead of the default 120 s, because
    // this script runs on the main thread. It only runs once permission is granted, so it never
    // waits on the permission prompt.
    private lazy var nowPlayingScript: NSAppleScript? = {
        let source = """
        with timeout of 2 seconds
            tell application "Music" to return {name of current track, sample rate of current track}
        end timeout
        """
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
    
    /// True when the AppleScript path decides the rate, which turns the log pairing off.
    /// While the permission question is open (`checking`) the log pairing stays on, so the device
    /// still follows the music, and the AppleScript reading takes over once permission is granted.
    var usesAppleScriptRate: Bool {
        guard Defaults.shared.useAppleScriptSampleRate else { return false }
        switch OutputDevices.musicPermission {
        case .checking, .denied, .undetermined:
            return false
        case .unknown, .granted:
            return true
        }
    }
    
    /// True when a track change should start (or wait to start) an AppleScript reading.
    private var wantsAppleScriptRate: Bool {
        guard Defaults.shared.useAppleScriptSampleRate else { return false }
        switch OutputDevices.musicPermission {
        case .denied, .undetermined:
            return false
        case .unknown, .checking, .granted:
            return true
        }
    }
    
    /// Called on the main thread from trackDidChange.
    private func startMusicPoll(expectedTitle: String?) {
        appleScriptGeneration += 1
        let generation = appleScriptGeneration
        let start = Date()
        
        guard OutputDevices.musicPermission != .granted else {
            pollMusic(expectedTitle: expectedTitle, generation: generation, attempt: 0, start: start)
            return
        }
        
        OutputDevices.requestMusicPermission { [weak self] permission in
            guard let self else { return }
            if permission == .granted {
                // If the track changed while the prompt was open, the generation check drops this poll.
                self.pollMusic(expectedTitle: expectedTitle, generation: generation, attempt: 0, start: start)
            }
            else {
                // Denied or no final answer: let the log pairing handle the current track.
                self.updateRequester.send()
            }
        }
    }
    
    /// Asks macOS whether this app may send Apple events to Music, showing the prompt if needed.
    /// Main thread only. `completion` runs on the main thread.
    private static func requestMusicPermission(completion: @escaping (MusicPermission) -> Void) {
        musicPermissionWaiters.append(completion)
        guard musicPermission != .checking else { return }
        musicPermission = .checking
        print("[AS159] \(logClock.string(from: Date())) asking for Apple Events permission")
        
        musicPermissionQueue.async {
            let music = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
            // Wildcard class and ID: "may this app send Music any Apple event". askUserIfNeeded
            // shows the prompt and blocks this queue until it's answered.
            let status = AEDeterminePermissionToAutomateTarget(music.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
            
            let permission: MusicPermission
            switch status {
            case OSStatus(noErr):
                permission = .granted
            case -1743: // errAEEventNotPermitted: the user said no, now or earlier
                permission = .denied
            default:
                // -600 (procNotFound): Music quit before macOS could ask. Not a "no", so the next
                // track change asks again. -1712 isn't expected here: the prompt doesn't expire.
                permission = .undetermined
            }
            
            DispatchQueue.main.async {
                print("[AS159] \(OutputDevices.logClock.string(from: Date())) Apple Events permission status \(status) -> \(permission)")
                OutputDevices.musicPermission = permission
                let waiters = OutputDevices.musicPermissionWaiters
                OutputDevices.musicPermissionWaiters = []
                waiters.forEach { $0(permission) }
            }
        }
    }
    
    private func readMusic() -> MusicReading {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !running.isEmpty else { return .notRunning }
        guard let script = nowPlayingScript else { return .failed(code: 0) }
        
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 here means the permission was revoked while the app was running.
            // -1712 here is Music taking over 2 s to answer, not the prompt: keep polling.
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
            OutputDevices.musicPermission = .denied
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
    
    /// Called on pairHandlingQueue for every lossless log line.
    private func recordMusicFormatLine(_ line: DatedPair<AudioFormat>) {
        musicFormatLines.append(line)
        if musicFormatLines.count > musicFormatLinesLimit {
            musicFormatLines.removeFirst(musicFormatLines.count - musicFormatLinesLimit)
        }
    }
    
    /// Picks the log line whose bit depth belongs to the track now playing.
    ///
    /// Music writes one line each time it loads a track, in play order, and with gapless
    /// playback it loads the next track while the current one plays. So right after a change
    /// the newest line can belong to the next track. The first line with the same rate that
    /// comes after the line used for the previous track is the current track's own line, even
    /// when the next track has the same rate and a different bit depth.
    /// If there is no such line, it falls back to the newest line with the same rate.
    private func musicFormatLine(forSampleRate sampleRate: Int) -> (line: DatedPair<AudioFormat>, isNext: Bool)? {
        let sameRate = musicFormatLines.filter { $0.object.sampleRate == sampleRate }
        if let next = sameRate.first(where: { lastUsedFormatLineDate == nil || $0.date > lastUsedFormatLineDate! }) {
            lastUsedFormatLineDate = next.date
            return (line: next, isNext: true)
        }
        return sameRate.last.map { (line: $0, isNext: false) }
    }
    
    /// Forget the log lines when Music quits: the next launch starts a new play order.
    private func observeMusicTermination() {
        musicTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.Music" else { return }
            self?.pairHandlingQueue.async {
                self?.musicFormatLines.removeAll()
                self?.lastUsedFormatLineDate = nil
            }
        }
    }
    
    private func applyMusicSampleRate(_ sampleRate: Int, elapsed: TimeInterval) {
        pairHandlingQueue.async { [weak self] in
            guard let self else { return }
            let match = self.musicFormatLine(forSampleRate: sampleRate)
            let bitDepth = match?.line.object.bitDepth
            let source = match.map { $0.isNext ? "next unused line" : "newest line, already used" } ?? "none"
            print("[AS159] \(OutputDevices.logClock.string(from: Date())) apply \(sampleRate) Hz / \(bitDepth.map(String.init) ?? "?") bit (bit depth from log: \(match != nil), \(source)) after +\(String(format: "%.2f", elapsed))s")
            self.switchLatestSampleRate(format: AudioFormat(sampleRate: sampleRate, bitDepth: bitDepth))
        }
    }
}
