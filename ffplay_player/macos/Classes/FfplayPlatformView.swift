import Cocoa
import FlutterMacOS

/// Platform view that hosts the SDL video player
public class FfplayPlatformView: NSView {
    private var viewIdentifier: Int64
    private var channel: FlutterMethodChannel?
    private var player: OpaquePointer?
    private var sdlView: NSView?
    private var eventTimer: Timer?
    private var statsTimer: Timer?
    
    // Player state
    private var isPlaying: Bool = false
    private var currentUrl: String = ""
    
    public init(viewIdentifier: Int64, arguments args: Any?, binaryMessenger messenger: FlutterBinaryMessenger) {
        self.viewIdentifier = viewIdentifier
        super.init(frame: .zero)
        
        // Set up method channel for this view instance
        channel = FlutterMethodChannel(
            name: "ffplay_player_view_\(viewIdentifier)",
            binaryMessenger: messenger
        )
        
        channel?.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call: call, result: result)
        }
        
        // Configure view
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        
        // Set up notification observer for frame changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        destroyPlayer()
        channel?.setMethodCallHandler(nil)
    }
    
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // View is now in a window, can start player operations
            startEventLoop()
        }
    }
    
    @objc private func frameDidChange() {
        // Update player size when view frame changes
        resizeToMatchBounds()
    }
    
    // MARK: - Method Channel Handling
    
    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        
        switch call.method {
        case "setUrl":
            if let url = args?["url"] as? String {
                setUrl(url)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARG", message: "URL is required", details: nil))
            }
            
        case "play":
            play { success in
                result(success)
            }
            
        case "pause":
            pause()
            result(nil)
            
        case "resume":
            resume()
            result(nil)
            
        case "stop":
            stop()
            result(nil)
            
        case "seek":
            if let position = args?["position"] as? Double {
                seek(position)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARG", message: "Position is required", details: nil))
            }
            
        case "seekRelative":
            if let delta = args?["delta"] as? Double {
                seekRelative(delta)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARG", message: "Delta is required", details: nil))
            }
            
        case "setVolume":
            if let volume = args?["volume"] as? Int {
                setVolume(volume)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARG", message: "Volume is required", details: nil))
            }
            
        case "setMute":
            if let muted = args?["muted"] as? Bool {
                setMute(muted)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARG", message: "Muted is required", details: nil))
            }
            
        case "getPosition":
            let position = getPosition()
            result(position)
            
        case "getDuration":
            let duration = getDuration()
            result(duration)
            
        case "isPlaying":
            result(isPlaying)
            
        case "getState":
            let state = getState()
            result(state)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Player Control Methods
    
    private func setUrl(_ url: String) {
        currentUrl = url
        
        // Create player if not exists
        if player == nil {
            player = FfplayNativePlayer.createPlayer()
        }
        
        if let player = player {
            FfplayNativePlayer.setUrl(player, url: url)
            
            // Set initial size
            let frame = self.bounds
            FfplayNativePlayer.setSize(player, width: Int32(frame.width), height: Int32(frame.height))
        }
    }
    
    private func play(completion: @escaping (Bool) -> Void) {
        guard let player = player else {
            completion(false)
            return
        }
        
        // Force layout to ensure bounds are correct
        self.layoutSubtreeIfNeeded()
        
        // Set the current view size before starting playback
        var frame = self.bounds
        if frame.width <= 0 || frame.height <= 0 {
            frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        }
        FfplayNativePlayer.setSize(player, width: Int32(frame.width), height: Int32(frame.height))
        
        // Start playback - this will be called on the main thread
        // which is correct for SDL on macOS
        let result = FfplayNativePlayer.start(player)
        
        if result == 0 {
            isPlaying = true
            
            // Delay embedding to ensure Flutter view has completed layout
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                self.embedSdlView()
                
                // Additional delayed resize to catch the correct size after layout
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self = self else { return }
                    self.resizeToMatchBounds()
                }
            }
            
            startStatsTimer()
            completion(true)
        } else {
            completion(false)
        }
    }
    
    /// Resize SDL window to match current bounds
    private func resizeToMatchBounds() {
        guard let player = player else { return }
        
        var frame = self.bounds
        if frame.width <= 0 || frame.height <= 0 {
            frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        }
        
        FfplayNativePlayer.resizeWindow(player, width: Int32(frame.width), height: Int32(frame.height))
        
        if let sdlView = sdlView {
            sdlView.frame = frame
        }
        
        print("FfplayPlatformView: Resized to \(frame.width)x\(frame.height)")
    }
    
    private func pause() {
        guard let player = player else { return }
        FfplayNativePlayer.pause(player, paused: 1)
        isPlaying = false
    }
    
    private func resume() {
        guard let player = player else { return }
        FfplayNativePlayer.pause(player, paused: 0)
        isPlaying = true
    }
    
    private func stop() {
        destroyPlayer()
        isPlaying = false
    }
    
    private func seek(_ position: Double) {
        guard let player = player else { return }
        FfplayNativePlayer.seek(player, position: position)
    }
    
    private func seekRelative(_ delta: Double) {
        guard let player = player else { return }
        FfplayNativePlayer.seekRelative(player, delta: delta)
    }
    
    private func setVolume(_ volume: Int) {
        guard let player = player else { return }
        FfplayNativePlayer.setVolume(player, volume: Int32(volume))
    }
    
    private func setMute(_ muted: Bool) {
        guard let player = player else { return }
        FfplayNativePlayer.setMute(player, muted: muted ? 1 : 0)
    }
    
    private func getPosition() -> Double {
        guard let player = player else { return 0 }
        return FfplayNativePlayer.getPosition(player)
    }
    
    private func getDuration() -> Double {
        guard let player = player else { return 0 }
        return FfplayNativePlayer.getDuration(player)
    }
    
    private func getState() -> String {
        if player == nil {
            return "idle"
        } else if isPlaying {
            return "playing"
        } else {
            return "paused"
        }
    }
    
    // MARK: - SDL View Embedding
    
    private func embedSdlView() {
        guard let player = player else { return }
        
        // Force layout to ensure bounds are correct
        self.layoutSubtreeIfNeeded()
        
        // Get the Flutter view bounds - use window's frame if bounds are invalid
        var frame = self.bounds
        if frame.width <= 0 || frame.height <= 0 {
            // Fallback to a reasonable default if bounds are not set
            frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        }
        
        // Get the native NSWindow pointer from the SDL window
        if let nsWindowPtr = FfplayNativePlayer.getNativeView(player) {
            // Convert the pointer to an NSWindow
            let nsWindow = Unmanaged<NSWindow>.fromOpaque(nsWindowPtr).takeUnretainedValue()
            
            // Get the contentView from the NSWindow
            let contentView = nsWindow.contentView
            
            // Remove from current window if needed
            contentView?.removeFromSuperview()
            
            // Resize the SDL window to match the Flutter view BEFORE embedding
            FfplayNativePlayer.resizeWindow(player, width: Int32(frame.width), height: Int32(frame.height))
            
            // Add to our view
            if let contentView = contentView {
                contentView.autoresizingMask = [.width, .height]
                contentView.frame = frame
                addSubview(contentView)
                sdlView = contentView
            }
            
            // Hide the original SDL window - make it invisible
            nsWindow.styleMask = [.borderless]
            nsWindow.level = .normal
            nsWindow.alphaValue = 0.0
            nsWindow.orderOut(nil)
            
            print("FfplayPlatformView: SDL view embedded successfully with size \(frame.width)x\(frame.height)")
        } else {
            print("FfplayPlatformView: Failed to get native view from player")
        }
    }
    
    private func unembedSdlView() {
        sdlView?.removeFromSuperview()
        sdlView = nil
    }
    
    // MARK: - Event Loop
    
    private func startEventLoop() {
        // Run SDL event loop periodically on main thread
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            _ = FfplayNativePlayer.runEventLoop(10)
            
            // Check for EOF
            if FfplayNativePlayer.isEof(player) {
                self.onPlaybackComplete()
            }
        }
        RunLoop.main.add(eventTimer!, forMode: .common)
    }
    
    private func stopEventLoop() {
        eventTimer?.invalidate()
        eventTimer = nil
    }
    
    // MARK: - Stats Timer
    
    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        RunLoop.main.add(statsTimer!, forMode: .common)
    }
    
    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }
    
    private func updateStats() {
        guard let player = player else { return }
        
        let position = FfplayNativePlayer.getPosition(player)
        let duration = FfplayNativePlayer.getDuration(player)
        
        channel?.invokeMethod("onStatsUpdate", arguments: [
            "position": position,
            "duration": duration,
            "state": getState()
        ])
    }
    
    private func onPlaybackComplete() {
        isPlaying = false
        stopStatsTimer()
        
        channel?.invokeMethod("onPlaybackComplete", arguments: nil)
    }
    
    // MARK: - Cleanup
    
    private func destroyPlayer() {
        stopStatsTimer()
        unembedSdlView()
        
        if let player = player {
            FfplayNativePlayer.destroy(player)
            self.player = nil
        }
    }
}
