import Cocoa
import FlutterMacOS

/// FfplayPlayerPlugin - Main plugin class that registers the platform view factory
public class FfplayPlayerPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var playerFactory: FfplayPlatformViewFactory?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ffplay_player", binaryMessenger: registrar.messenger)
        
        // Create and register the platform view factory
        let factory = FfplayPlatformViewFactory(messenger: registrar.messenger)
        registrar.register(factory, withId: "ffplay_player_view")
        
        let instance = FfplayPlayerPlugin()
        instance.channel = channel
        instance.playerFactory = factory
        
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
            
        case "initialize":
            // Initialize the native library
            FfplayNativePlayer.initialize()
            result(nil)
            
        case "extractAudio":
            // Extract audio from video file using ffmpeg_transcoder_run
            guard let args = call.arguments as? [String: Any],
                  let inputPath = args["inputPath"] as? String,
                  let outputPath = args["outputPath"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "inputPath and outputPath are required", details: nil))
                return
            }
            
            let sampleRate = args["sampleRate"] as? Int32 ?? 16000
            
            // Run audio extraction in background thread
            DispatchQueue.global(qos: .userInitiated).async {
                let ret = FfplayNativePlayer.extractAudio(
                    inputPath: inputPath,
                    outputPath: outputPath,
                    sampleRate: sampleRate
                )
                DispatchQueue.main.async {
                    result(ret)
                }
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
