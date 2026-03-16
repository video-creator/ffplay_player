import 'package:flutter_test/flutter_test.dart';
import 'package:ffplay_player/ffplay_player.dart';
import 'package:ffplay_player/ffplay_player_platform_interface.dart';
import 'package:ffplay_player/ffplay_player_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFfplayPlayerPlatform
    with MockPlatformInterfaceMixin
    implements FfplayPlayerPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FfplayPlayerPlatform initialPlatform = FfplayPlayerPlatform.instance;

  test('$MethodChannelFfplayPlayer is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFfplayPlayer>());
  });

  test('getPlatformVersion', () async {
    FfplayPlayer ffplayPlayerPlugin = FfplayPlayer();
    MockFfplayPlayerPlatform fakePlatform = MockFfplayPlayerPlatform();
    FfplayPlayerPlatform.instance = fakePlatform;

    expect(await ffplayPlayerPlugin.getPlatformVersion(), '42');
  });
}
