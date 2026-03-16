import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'ffplay_player_method_channel.dart';

abstract class FfplayPlayerPlatform extends PlatformInterface {
  /// Constructs a FfplayPlayerPlatform.
  FfplayPlayerPlatform() : super(token: _token);

  static final Object _token = Object();

  static FfplayPlayerPlatform _instance = MethodChannelFfplayPlayer();

  /// The default instance of [FfplayPlayerPlatform] to use.
  ///
  /// Defaults to [MethodChannelFfplayPlayer].
  static FfplayPlayerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FfplayPlayerPlatform] when
  /// they register themselves.
  static set instance(FfplayPlayerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
