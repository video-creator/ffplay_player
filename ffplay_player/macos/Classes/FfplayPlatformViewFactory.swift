import Cocoa
import FlutterMacOS

/// Factory class to create FfplayPlatformView instances
public class FfplayPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger
    
    public init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }
    
    public func create(withViewIdentifier viewIdentifier: Int64, arguments args: Any?) -> NSView {
        return FfplayPlatformView(
            viewIdentifier: viewIdentifier,
            arguments: args,
            binaryMessenger: messenger
        )
    }
    
    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}
