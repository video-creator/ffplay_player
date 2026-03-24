import Cocoa

/// Wrapper around the native ffplay_jni library
public class FfplayNativePlayer {
    // MARK: - Function Pointers
    
    private typealias FFplayPlayerCreate = @convention(c) () -> OpaquePointer
    private typealias FFplayPlayerSetUrl = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void
    private typealias FFplayPlayerSetSize = @convention(c) (OpaquePointer, Int32, Int32) -> Void
    private typealias FFplayPlayerSetVolume = @convention(c) (OpaquePointer, Int32) -> Void
    private typealias FFplayPlayerStart = @convention(c) (OpaquePointer) -> Int32
    private typealias FFplayPlayerPause = @convention(c) (OpaquePointer, Int32) -> Void
    private typealias FFplayPlayerSeek = @convention(c) (OpaquePointer, Double) -> Void
    private typealias FFplayPlayerIsSeeking = @convention(c) (OpaquePointer) -> Int32
    private typealias FFplayPlayerSeekRelative = @convention(c) (OpaquePointer, Double) -> Void
    private typealias FFplayPlayerSetVolumeLive = @convention(c) (OpaquePointer, Int32) -> Void
    private typealias FFplayPlayerSetMute = @convention(c) (OpaquePointer, Int32) -> Void
    private typealias FFplayPlayerToggleFullscreen = @convention(c) (OpaquePointer) -> Void
    private typealias FFplayPlayerDestroy = @convention(c) (OpaquePointer) -> Void
    private typealias FFplayPlayerRunEventLoop = @convention(c) (Int32) -> Int32
    private typealias FFplayPlayerIsEof = @convention(c) (OpaquePointer) -> Int32
    private typealias FFplayPlayerGetPosition = @convention(c) (OpaquePointer) -> Double
    private typealias FFplayPlayerGetDuration = @convention(c) (OpaquePointer) -> Double
    private typealias FFplayPlayerGetWindowId = @convention(c) (OpaquePointer) -> UInt32
    private typealias FFplayPlayerGetNativeView = @convention(c) (OpaquePointer) -> UnsafeMutableRawPointer?
    private typealias FFplayPlayerResizeWindow = @convention(c) (OpaquePointer, Int32, Int32) -> Void
    private typealias FFplayPlayerSetLoop = @convention(c) (OpaquePointer, Int32) -> Void
    private typealias FFplayPlayerSetSpeed = @convention(c) (OpaquePointer, Double) -> Void
    private typealias FFplayPlayerGetSpeed = @convention(c) (OpaquePointer) -> Double
    private typealias FFplayPlayerSetStartTime = @convention(c) (OpaquePointer, Double) -> Void

    // ASR (Automatic Speech Recognition) function types
    // C signature: int ffplay_player_init_asr(FFPlayer*, const char* model_dir, const char* vad_model, const char* punct_model, callback, void* userdata)
    private typealias FFplayPlayerInitAsr = @convention(c) (
        OpaquePointer,
        UnsafePointer<CChar>,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        @convention(c) (UnsafePointer<CChar>?, Int32, Double, UnsafeMutableRawPointer?) -> Void,
        UnsafeMutableRawPointer?
    ) -> Int32
    // C signature: void ffplay_player_enable_asr(FFPlayer*, int enable)
    private typealias FFplayPlayerEnableAsr = @convention(c) (OpaquePointer, Int32) -> Void
    // C signature: void ffplay_player_reset_asr(FFPlayer*)
    private typealias FFplayPlayerResetAsr = @convention(c) (OpaquePointer) -> Void
    // C signature: void ffplay_player_destroy_asr(FFPlayer*)
    private typealias FFplayPlayerDestroyAsr = @convention(c) (OpaquePointer) -> Void

    // FFmpeg Transcoder functions for audio extraction
    private typealias FFmpegTranscoderInit = @convention(c) () -> OpaquePointer?
    private typealias FFmpegTranscoderRun = @convention(c) (OpaquePointer, Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias FFmpegTranscoderCancel = @convention(c) (OpaquePointer) -> Void
    private typealias FFmpegTranscoderFree = @convention(c) (OpaquePointer) -> Void
    private typealias FFmpegTranscoderIsRunning = @convention(c) (OpaquePointer) -> Int32
    private typealias FFmpegTranscoderGetResult = @convention(c) (OpaquePointer) -> Int32
    
    private typealias InitDynload = @convention(c) () -> Void
    private typealias AvformatNetworkInit = @convention(c) () -> Void
    
    // MARK: - Loaded Functions
    
    private static var handle: UnsafeMutableRawPointer?
    private static var isInitialized = false
    
    private static var _createPlayer: FFplayPlayerCreate?
    private static var _setUrl: FFplayPlayerSetUrl?
    private static var _setSize: FFplayPlayerSetSize?
    private static var _setVolume: FFplayPlayerSetVolume?
    private static var _start: FFplayPlayerStart?
    private static var _pause: FFplayPlayerPause?
    private static var _seek: FFplayPlayerSeek?
    private static var _isSeeking: FFplayPlayerIsSeeking?
    private static var _seekRelative: FFplayPlayerSeekRelative?
    private static var _setVolumeLive: FFplayPlayerSetVolumeLive?
    private static var _setMute: FFplayPlayerSetMute?
    private static var _toggleFullscreen: FFplayPlayerToggleFullscreen?
    private static var _destroy: FFplayPlayerDestroy?
    private static var _runEventLoop: FFplayPlayerRunEventLoop?
    private static var _isEof: FFplayPlayerIsEof?
    private static var _getPosition: FFplayPlayerGetPosition?
    private static var _getDuration: FFplayPlayerGetDuration?
    private static var _getWindowId: FFplayPlayerGetWindowId?
    private static var _getNativeView: FFplayPlayerGetNativeView?
    private static var _resizeWindow: FFplayPlayerResizeWindow?
    private static var _setLoop: FFplayPlayerSetLoop?
    private static var _setSpeed: FFplayPlayerSetSpeed?
    private static var _getSpeed: FFplayPlayerGetSpeed?
    private static var _setStartTime: FFplayPlayerSetStartTime?

    // ASR functions
    private static var _initAsr: FFplayPlayerInitAsr?
    private static var _enableAsr: FFplayPlayerEnableAsr?
    private static var _resetAsr: FFplayPlayerResetAsr?
    private static var _destroyAsr: FFplayPlayerDestroyAsr?
    
    // FFmpeg Transcoder functions
    private static var _transcoderInit: FFmpegTranscoderInit?
    private static var _transcoderRun: FFmpegTranscoderRun?
    private static var _transcoderCancel: FFmpegTranscoderCancel?
    private static var _transcoderFree: FFmpegTranscoderFree?
    private static var _transcoderIsRunning: FFmpegTranscoderIsRunning?
    private static var _transcoderGetResult: FFmpegTranscoderGetResult?
    
    // MARK: - Initialization
    
    public static func initialize() {
        guard !isInitialized else { return }
        
        // Load the library - try new name first, then old name for backward compatibility
        let libraryPath = Bundle.main.path(forResource: "libffmpeg_jni", ofType: "dylib", inDirectory: "Frameworks")
            ?? Bundle.main.path(forResource: "libffmpeg_jni", ofType: "dylib", inDirectory: "Frameworks/Libraries")
            ?? Bundle.main.path(forResource: "libffplay_jni", ofType: "dylib", inDirectory: "Frameworks")
            ?? Bundle.main.path(forResource: "libffplay_jni", ofType: "dylib", inDirectory: "Frameworks/Libraries")
        
        if let path = libraryPath {
            handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        }
        
        // If not found in bundle, try @rpath
        if handle == nil {
            handle = dlopen("libffmpeg_jni.dylib", RTLD_NOW | RTLD_LOCAL)
        }
        // Fall back to old name
        if handle == nil {
            handle = dlopen("libffplay_jni.dylib", RTLD_NOW | RTLD_LOCAL)
        }
        
        guard let handle = handle else {
            print("FfplayNativePlayer: Failed to load libffmpeg_jni.dylib or libffplay_jni.dylib")
            return
        }
        
        // Load all functions
        _createPlayer = unsafeBitCast(dlsym(handle, "ffplay_player_create"), to: FFplayPlayerCreate.self)
        _setUrl = unsafeBitCast(dlsym(handle, "ffplay_player_set_url"), to: FFplayPlayerSetUrl.self)
        _setSize = unsafeBitCast(dlsym(handle, "ffplay_player_set_size"), to: FFplayPlayerSetSize.self)
        _setVolume = unsafeBitCast(dlsym(handle, "ffplay_player_set_volume"), to: FFplayPlayerSetVolume.self)
        _start = unsafeBitCast(dlsym(handle, "ffplay_player_start"), to: FFplayPlayerStart.self)
        _pause = unsafeBitCast(dlsym(handle, "ffplay_player_pause"), to: FFplayPlayerPause.self)
        _seek = unsafeBitCast(dlsym(handle, "ffplay_player_seek"), to: FFplayPlayerSeek.self)
        _isSeeking = unsafeBitCast(dlsym(handle, "ffplay_player_is_seeking"), to: FFplayPlayerIsSeeking.self)
        _seekRelative = unsafeBitCast(dlsym(handle, "ffplay_player_seek_relative"), to: FFplayPlayerSeekRelative.self)
        _setVolumeLive = unsafeBitCast(dlsym(handle, "ffplay_player_set_volume_live"), to: FFplayPlayerSetVolumeLive.self)
        _setMute = unsafeBitCast(dlsym(handle, "ffplay_player_set_mute"), to: FFplayPlayerSetMute.self)
        _toggleFullscreen = unsafeBitCast(dlsym(handle, "ffplay_player_toggle_fullscreen"), to: FFplayPlayerToggleFullscreen.self)
        _destroy = unsafeBitCast(dlsym(handle, "ffplay_player_destroy"), to: FFplayPlayerDestroy.self)
        _runEventLoop = unsafeBitCast(dlsym(handle, "ffplay_player_run_event_loop"), to: FFplayPlayerRunEventLoop.self)
        _isEof = unsafeBitCast(dlsym(handle, "ffplay_player_is_eof"), to: FFplayPlayerIsEof.self)
        _getPosition = unsafeBitCast(dlsym(handle, "ffplay_player_get_position"), to: FFplayPlayerGetPosition.self)
        _getDuration = unsafeBitCast(dlsym(handle, "ffplay_player_get_duration"), to: FFplayPlayerGetDuration.self)
        _getWindowId = unsafeBitCast(dlsym(handle, "ffplay_player_get_window_id"), to: FFplayPlayerGetWindowId.self)
        _getNativeView = unsafeBitCast(dlsym(handle, "ffplay_player_get_native_view"), to: FFplayPlayerGetNativeView.self)
        _resizeWindow = unsafeBitCast(dlsym(handle, "ffplay_player_resize_window"), to: FFplayPlayerResizeWindow.self)
        _setLoop = unsafeBitCast(dlsym(handle, "ffplay_player_set_loop"), to: FFplayPlayerSetLoop.self)
        _setSpeed = unsafeBitCast(dlsym(handle, "ffplay_player_set_speed"), to: FFplayPlayerSetSpeed.self)
        _getSpeed = unsafeBitCast(dlsym(handle, "ffplay_player_get_speed"), to: FFplayPlayerGetSpeed.self)
        _setStartTime = unsafeBitCast(dlsym(handle, "ffplay_player_set_start_time"), to: FFplayPlayerSetStartTime.self)

        // Load ASR functions (optional — may not be present in older builds)
        if let sym = dlsym(handle, "ffplay_player_init_asr") {
            _initAsr = unsafeBitCast(sym, to: FFplayPlayerInitAsr.self)
        }
        if let sym = dlsym(handle, "ffplay_player_enable_asr") {
            _enableAsr = unsafeBitCast(sym, to: FFplayPlayerEnableAsr.self)
        }
        if let sym = dlsym(handle, "ffplay_player_reset_asr") {
            _resetAsr = unsafeBitCast(sym, to: FFplayPlayerResetAsr.self)
        }
        if let sym = dlsym(handle, "ffplay_player_destroy_asr") {
            _destroyAsr = unsafeBitCast(sym, to: FFplayPlayerDestroyAsr.self)
        }
        
        // Load FFmpeg transcoder functions
        _transcoderInit = unsafeBitCast(dlsym(handle, "ffmpeg_transcoder_init"), to: FFmpegTranscoderInit.self)
        _transcoderRun = unsafeBitCast(dlsym(handle, "ffmpeg_transcoder_run"), to: FFmpegTranscoderRun.self)
        _transcoderCancel = unsafeBitCast(dlsym(handle, "ffmpeg_transcoder_cancel"), to: FFmpegTranscoderCancel.self)
        _transcoderFree = unsafeBitCast(dlsym(handle, "ffmpeg_transcoder_free"), to: FFmpegTranscoderFree.self)
        _transcoderIsRunning = unsafeBitCast(dlsym(handle, "ffmpeg_transcoder_is_running"), to: FFmpegTranscoderIsRunning.self)
        _transcoderGetResult = unsafeBitCast(dlsym(handle, "ffmpeg_transcoder_get_result"), to: FFmpegTranscoderGetResult.self)
        
        // Call initialization functions
        if let initDynload = unsafeBitCast(dlsym(handle, "init_dynload"), to: InitDynload?.self) {
            initDynload()
        }
        if let networkInit = unsafeBitCast(dlsym(handle, "avformat_network_init"), to: AvformatNetworkInit?.self) {
            networkInit()
        }
        
        isInitialized = true
        print("FfplayNativePlayer: Library loaded successfully")
    }
    
    // MARK: - Player API
    
    public static func createPlayer() -> OpaquePointer? {
        return _createPlayer?()
    }
    
    public static func setUrl(_ player: OpaquePointer, url: String) {
        url.withCString { cString in
            _setUrl?(player, cString)
        }
    }
    
    public static func setSize(_ player: OpaquePointer, width: Int32, height: Int32) {
        _setSize?(player, width, height)
    }
    
    public static func setVolume(_ player: OpaquePointer, volume: Int32) {
        _setVolume?(player, volume)
    }
    
    public static func start(_ player: OpaquePointer) -> Int32 {
        return _start?(player) ?? -1
    }
    
    public static func pause(_ player: OpaquePointer, paused: Int32) {
        _pause?(player, paused)
    }
    
    public static func seek(_ player: OpaquePointer, position: Double) {
        _seek?(player, position)
    }
    
    public static func isSeeking(_ player: OpaquePointer) -> Bool {
        return (_isSeeking?(player) ?? 0) != 0
    }
    
    public static func seekRelative(_ player: OpaquePointer, delta: Double) {
        _seekRelative?(player, delta)
    }
    
    public static func setVolumeLive(_ player: OpaquePointer, volume: Int32) {
        _setVolumeLive?(player, volume)
    }
    
    public static func setMute(_ player: OpaquePointer, muted: Int32) {
        _setMute?(player, muted)
    }
    
    public static func toggleFullscreen(_ player: OpaquePointer) {
        _toggleFullscreen?(player)
    }
    
    public static func destroy(_ player: OpaquePointer) {
        _destroy?(player)
    }
    
    public static func runEventLoop(_ timeoutMs: Int32) -> Int32 {
        return _runEventLoop?(timeoutMs) ?? 0
    }
    
    public static func isEof(_ player: OpaquePointer) -> Bool {
        return (_isEof?(player) ?? 0) != 0
    }
    
    public static func getPosition(_ player: OpaquePointer) -> Double {
        return _getPosition?(player) ?? 0
    }
    
    public static func getDuration(_ player: OpaquePointer) -> Double {
        return _getDuration?(player) ?? 0
    }
    
    public static func getWindowId(_ player: OpaquePointer) -> UInt32? {
        guard let funcPtr = _getWindowId else { return nil }
        let windowId = funcPtr(player)
        return windowId != 0 ? windowId : nil
    }
    
    /// Get the native NSWindow pointer for embedding.
    /// Returns the NSWindow* of the SDL window on macOS.
    public static func getNativeView(_ player: OpaquePointer) -> UnsafeMutableRawPointer? {
        return _getNativeView?(player)
    }
    
    /// Resize the SDL window to match the given dimensions.
    /// This should be called after embedding to ensure the renderer matches the view size.
    public static func resizeWindow(_ player: OpaquePointer, width: Int32, height: Int32) {
        _resizeWindow?(player, width, height)
    }
    
    /// Set loop count (0 = infinite, 1 = play once).
    public static func setLoop(_ player: OpaquePointer, loop: Int32) {
        _setLoop?(player, loop)
    }
    
    /// Set playback speed (0.25 to 4.0, 1.0 = normal).
    public static func setSpeed(_ player: OpaquePointer, speed: Double) {
        _setSpeed?(player, speed)
    }
    
    /// Get current playback speed.
    public static func getSpeed(_ player: OpaquePointer) -> Double {
        return _getSpeed?(player) ?? 1.0
    }
    
    /// Set start time for playback.
    /// Call this before start() to begin playback from a specific position.
    /// This avoids the brief flash of the beginning when seeking after playback complete.
    /// @param player      The player instance.
    /// @param startTimeS  Start position in seconds. Use -1 to start from beginning.
    public static func setStartTime(_ player: OpaquePointer, startTimeS: Double) {
        _setStartTime?(player, startTimeS)
    }
    
    // MARK: - ASR (Automatic Speech Recognition)
    
    /// Initialise the ASR recognizer for a player instance.
    ///
    /// - Parameters:
    ///   - player:     The player instance.
    ///   - modelDir:   Path to directory containing sherpa-onnx ASR model files.
    ///   - vadModel:   Path to silero_vad.onnx. Pass nil to disable VAD and
    ///                 rely on ASR endpoint detection.
    ///   - punctModel: Path to ct-transformer punctuation model.onnx.
    ///                 Pass nil to disable punctuation.
    ///   - callback:   C-convention callback invoked with recognition results.
    ///   - userData:   Opaque pointer passed through to callback (use Unmanaged).
    /// - Returns: 0 on success, -1 on failure.
    @discardableResult
    public static func initAsr(
        _ player: OpaquePointer,
        modelDir: String,
        vadModel: String? = nil,
        punctModel: String? = nil,
        callback: @convention(c) (UnsafePointer<CChar>?, Int32, Double, UnsafeMutableRawPointer?) -> Void,
        userData: UnsafeMutableRawPointer?
    ) -> Int32 {
        guard let fn = _initAsr else { return -1 }
        return modelDir.withCString { cDir in
            func callWithPunct(_ cVad: UnsafePointer<CChar>?) -> Int32 {
                if let punct = punctModel, !punct.isEmpty {
                    return punct.withCString { cPunct in
                        fn(player, cDir, cVad, cPunct, callback, userData)
                    }
                } else {
                    return fn(player, cDir, cVad, nil, callback, userData)
                }
            }
            if let vad = vadModel, !vad.isEmpty {
                return vad.withCString { cVad in callWithPunct(cVad) }
            } else {
                return callWithPunct(nil)
            }
        }
    }
    
    /// Enable or disable ASR audio feeding (without destroying the recognizer).
    public static func enableAsr(_ player: OpaquePointer, enable: Bool) {
        _enableAsr?(player, enable ? 1 : 0)
    }
    
    /// Reset the ASR recognizer state (e.g., after seek).
    public static func resetAsr(_ player: OpaquePointer) {
        _resetAsr?(player)
    }
    
    /// Destroy the ASR context for this player.
    public static func destroyAsr(_ player: OpaquePointer) {
        _destroyAsr?(player)
    }
    
    // MARK: - Audio Extraction (using FFmpeg Transcoder)
    
    /// Extract audio from a media file to WAV format using ffmpeg_transcoder_run.
    /// This is useful for ASR (speech recognition) preprocessing.
    ///
    /// - Parameters:
    ///   - inputPath: Path to the input media file (video/audio)
    ///   - outputPath: Path for the output WAV file
    ///   - sampleRate: Desired sample rate (e.g., 16000 for ASR)
    /// - Returns: 0 on success, negative on failure
    public static func extractAudio(inputPath: String, outputPath: String, sampleRate: Int32 = 16000) -> Int32 {
        guard let transcoder = _transcoderInit?() else {
            print("FfplayNativePlayer: Failed to init transcoder")
            return -1
        }
        
        defer {
            _transcoderFree?(transcoder)
        }
        
        // Build ffmpeg command arguments for audio extraction
        // ffmpeg -i input -vn -acodec pcm_s16le -ar 16000 -ac 1 output.wav
        let args = [
            "ffmpeg",
            "-i", inputPath,
            "-vn",                    // No video
            "-acodec", "pcm_s16le",   // 16-bit PCM
            "-ar", String(sampleRate), // Sample rate
            "-ac", "1",               // Mono
            "-y",                     // Overwrite output
            outputPath
        ]
        
        // Convert to C strings
        var cArgs = args.map { $0.withCString { strdup($0) } }
        cArgs.append(nil) // Null terminator
        
        defer {
            cArgs.forEach { if let ptr = $0 { free(ptr) } }
        }
        
        // Run transcoder - pass pointer to the array
        cArgs.withUnsafeMutableBufferPointer { buffer in
            _transcoderRun?(transcoder, Int32(args.count), buffer.baseAddress)
        }
        
        // Wait for completion (simple polling)
        while (_transcoderIsRunning?(transcoder) ?? 0) != 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        return _transcoderGetResult?(transcoder) ?? -1
    }
    
    /// Create a new transcoder instance.
    public static func createTranscoder() -> OpaquePointer? {
        return _transcoderInit?()
    }
    
    /// Run transcoder with custom arguments.
    public static func runTranscoder(_ transcoder: OpaquePointer, args: [String]) {
        var cArgs = args.map { $0.withCString { strdup($0) } }
        cArgs.append(nil)
        
        defer {
            cArgs.forEach { if let ptr = $0 { free(ptr) } }
        }
        
        cArgs.withUnsafeMutableBufferPointer { buffer in
            _transcoderRun?(transcoder, Int32(args.count), buffer.baseAddress)
        }
    }
    
    /// Check if transcoder is running.
    public static func isTranscoderRunning(_ transcoder: OpaquePointer) -> Bool {
        return (_transcoderIsRunning?(transcoder) ?? 0) != 0
    }
    
    /// Get transcoder result.
    public static func getTranscoderResult(_ transcoder: OpaquePointer) -> Int32 {
        return _transcoderGetResult?(transcoder) ?? -1
    }
    
    /// Cancel transcoder.
    public static func cancelTranscoder(_ transcoder: OpaquePointer) {
        _transcoderCancel?(transcoder)
    }
    
    /// Free transcoder.
    public static func freeTranscoder(_ transcoder: OpaquePointer) {
        _transcoderFree?(transcoder)
    }
}
