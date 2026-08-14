# Flutter's generated registrant keeps plugin entry points reachable.
-keep class io.flutter.plugins.** { *; }

# Snail's platform channels instantiate these classes by name.
-keep class com.snail.audio.SnailAudioPlugin { *; }
-keep class com.snail.snail.SnailSessionService { *; }

# flutter_webrtc loads native peer-connection classes reflectively.
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
