#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ffplay_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ffplay_player'
  s.version          = '0.0.1'
  s.summary          = 'A Flutter plugin for video playback using ffplay_jni.'
  s.description      = <<-DESC
A Flutter plugin for video playback using ffplay_jni.
Supports seek, pause, volume control and embedded video rendering.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.swift_version = '5.0'
  
  # Preserve all libraries
  s.preserve_paths = 'Libraries/**/*'
  
  # Include all dynamic libraries
  s.vendored_libraries = [
    'Libraries/libffmpeg_jni.dylib',
    'Libraries/libSDL2-2.0.0.dylib',
    'Libraries/libfdk-aac.2.dylib',
    'Libraries/libx265.215.dylib',
    'Libraries/liblzma.5.dylib',
    'Libraries/libopus.0.dylib',
    'Libraries/libmp3lame.0.dylib',
    'Libraries/libxcb.1.dylib',
    'Libraries/libxcb-shm.0.dylib',
    'Libraries/libxcb-shape.0.dylib',
    'Libraries/libxcb-xfixes.0.dylib'
  ]
  
  # Configure build settings
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/Libraries'
  }
  
  # Add required system frameworks
  s.frameworks = [
    'Cocoa', 
    'OpenGL', 
    'IOKit',
    'CoreVideo',
    'CoreMedia',
    'CoreFoundation',
    'VideoToolbox',
    'CoreServices',
    'Security',
    'Metal',
    'CoreImage',
    'AppKit',
    'AudioToolbox',
    'Foundation',
    'CoreAudio',
    'AVFoundation',
    'CoreGraphics'
  ]
  
  # Link against system libraries
  s.xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -lbz2 -lz -liconv -lxml2 -lm -lpthread -ldl -ldl'
  }
end
