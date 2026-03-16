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
    
    // MARK: - Initialization
    
    public static func initialize() {
        guard !isInitialized else { return }
        
        // Load the library
        let libraryPath = Bundle.main.path(forResource: "libffplay_jni", ofType: "dylib", inDirectory: "Frameworks")
            ?? Bundle.main.path(forResource: "libffplay_jni", ofType: "dylib", inDirectory: "Frameworks/Libraries")
        
        if let path = libraryPath {
            handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        }
        
        // If not found in bundle, try @rpath
        if handle == nil {
            handle = dlopen("libffplay_jni.dylib", RTLD_NOW | RTLD_LOCAL)
        }
        
        guard let handle = handle else {
            print("FfplayNativePlayer: Failed to load libffplay_jni.dylib")
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
}
