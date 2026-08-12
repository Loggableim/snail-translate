package com.snail.audio;

import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.NoiseSuppressor;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.AudioManager;
import android.media.AudioFocusRequest;
import android.media.AudioAttributes;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;
import android.content.Context;
import android.content.Intent;
import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.util.Log;
import android.util.Base64;

import androidx.annotation.NonNull;

import java.nio.ByteBuffer;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import com.snail.snail.SnailSessionService;

/**
 * Snail Audio Plugin — Android Platform Channel.
 *
 * Provides:
 * - Acoustic Echo Cancellation (AEC) via Android AudioFX
 * - Noise Suppression via Android AudioFX
 * - Low-latency audio capture with AEC applied
 * - Audio session management
 *
 * Usage from Flutter:
 *   final snailAudio = SnailAudioPlugin();
 *   await snailAudio.initialize(sampleRate: 16000);
 *   await snailAudio.startCapture();
 *   snailAudio.audioStream.listen((bytes) { ... });
 */
public class SnailAudioPlugin implements FlutterPlugin, ActivityAware, MethodCallHandler, EventChannel.StreamHandler {
    private static final String TAG = "SnailAudio";
    private static final String DEVICE_KEY_ALIAS = "snail.device.identity";
    private static final String METHOD_CHANNEL = "com.snail.audio/method";
    private static final String EVENT_CHANNEL = "com.snail.audio/stream";

    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private EventChannel standaloneEventChannel;
    private EventChannel.EventSink eventSink;
    private EventChannel.EventSink standaloneEventSink;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private Context applicationContext;
    private Activity activity;
    private Result pendingPermissionResult;
    private static final int MICROPHONE_PERMISSION_REQUEST = 7314;

    // Audio
    private AudioRecord audioRecord;
    private AcousticEchoCanceler aec;
    private NoiseSuppressor noiseSuppressor;
    private Thread captureThread;
    private volatile boolean isCapturing = false;
    private volatile boolean standaloneCapturing = false;
    private AudioRecord phoneRecord;
    private AudioRecord headsetRecord;
    private AcousticEchoCanceler standalonePhoneAec;
    private AcousticEchoCanceler standaloneHeadsetAec;
    private NoiseSuppressor standalonePhoneNs;
    private NoiseSuppressor standaloneHeadsetNs;
    private AudioTrack playbackTrack;
    private int playbackRate = 24000;
    private String playbackOutput = "default";
    private AudioManager audioManager;
    private int previousAudioMode = AudioManager.MODE_NORMAL;
    private boolean communicationModeActive = false;
    private AudioFocusRequest playbackFocusRequest;
    private boolean headsetRouteActive = false;
    private volatile long suppressCaptureUntilMs = 0L;
    private boolean standaloneHasHeadset = false;
    private String preferredInput = "auto";
    private Thread standalonePhoneThread;
    private Thread standaloneHeadsetThread;

    // Config
    private int sampleRate = 16000;
    private int channelConfig = AudioFormat.CHANNEL_IN_MONO;
    private int audioFormat = AudioFormat.ENCODING_PCM_16BIT;
    private boolean aecEnabled = true;
    private boolean noiseSuppressionEnabled = true;
    private int bufferSize;

    // ── Plugin Lifecycle ──────────────────────────────────────────────

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        applicationContext = binding.getApplicationContext();
        audioManager = (AudioManager) applicationContext.getSystemService(Context.AUDIO_SERVICE);
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler(this);

        eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
        eventChannel.setStreamHandler(this);
        standaloneEventChannel = new EventChannel(binding.getBinaryMessenger(), "com.snail.audio/standalone_stream");
        standaloneEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override public void onListen(Object arguments, EventChannel.EventSink events) { standaloneEventSink = events; }
            @Override public void onCancel(Object arguments) { standaloneEventSink = null; }
        });

        Log.i(TAG, "SnailAudioPlugin attached");
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        stopCapture();
        stopStandaloneCapture();
        stopPlayback();
        restoreAudioMode();
        applicationContext = null;
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
        Log.i(TAG, "SnailAudioPlugin detached");
    }

    // ── Method Channel ────────────────────────────────────────────────

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "initialize":
                handleInitialize(call, result);
                break;
            case "requestMicrophonePermission":
                requestMicrophonePermission(result);
                break;
            case "startCapture":
                handleStartCapture(result);
                break;
            case "startStandaloneCapture":
                handleStartStandaloneCapture(call, result);
                break;
            case "stopStandaloneCapture":
                stopStandaloneCapture();
                result.success(null);
                break;
            case "stopCapture":
                handleStopCapture(result);
                break;
            case "playPcm16":
                handlePlayPcm16(call, result);
                break;
            case "stopPlayback":
                stopPlayback();
                result.success(null);
                break;
            case "playTestTone":
                handlePlayTestTone(result);
                break;
            case "isAecAvailable":
                result.success(AcousticEchoCanceler.isAvailable());
                break;
            case "isNoiseSuppressorAvailable":
                result.success(NoiseSuppressor.isAvailable());
                break;
            case "isHeadsetConnected":
                result.success(isHeadsetConnected());
                break;
            case "setInput":
                preferredInput = call.argument("input") == null ? "auto" : (String) call.argument("input");
                result.success(null);
                break;
            case "getAudioDiagnostics":
                result.success(audioDiagnostics());
                break;
            case "getDevicePublicKey":
                try {
                    result.success(getDevicePublicKey());
                } catch (Exception error) {
                    result.error("DEVICE_KEY_ERROR", error.getMessage(), null);
                }
                break;
            case "signDevicePayload":
                try {
                    String payload = call.argument("payload");
                    result.success(signDevicePayload(payload == null ? "" : payload));
                } catch (Exception error) {
                    result.error("DEVICE_SIGNATURE_ERROR", error.getMessage(), null);
                }
                break;
            case "setAecEnabled":
                aecEnabled = call.argument("enabled");
                result.success(null);
                break;
            case "setNoiseSuppressionEnabled":
                noiseSuppressionEnabled = call.argument("enabled");
                result.success(null);
                break;
            case "getAudioSessionId":
                if (audioRecord != null) {
                    result.success(audioRecord.getAudioSessionId());
                } else {
                    result.success(null);
                }
                break;
            case "startSessionKeepAlive":
                startSessionKeepAlive();
                result.success(null);
                break;
            case "stopSessionKeepAlive":
                stopSessionKeepAlive();
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    private void requestMicrophonePermission(Result result) {
        if (applicationContext == null || android.os.Build.VERSION.SDK_INT < 23) {
            result.success(true);
            return;
        }
        if (applicationContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED) {
            result.success(true);
            return;
        }
        if (activity == null) {
            result.success(false);
            return;
        }
        pendingPermissionResult = result;
        activity.requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},
                MICROPHONE_PERMISSION_REQUEST);
    }

    @Override public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        binding.addRequestPermissionsResultListener((requestCode, permissions, grantResults) -> {
            if (requestCode != MICROPHONE_PERMISSION_REQUEST || pendingPermissionResult == null) return false;
            boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            Result pending = pendingPermissionResult;
            pendingPermissionResult = null;
            pending.success(granted);
            return true;
        });
    }

    @Override public void onDetachedFromActivityForConfigChanges() { activity = null; }
    @Override public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) { onAttachedToActivity(binding); }
    @Override public void onDetachedFromActivity() { activity = null; }

    private void handleInitialize(MethodCall call, Result result) {
        sampleRate = call.argument("sampleRate");
        if (sampleRate == 0) sampleRate = 16000;

        aecEnabled = call.hasArgument("aecEnabled") ? call.argument("aecEnabled") : true;
        noiseSuppressionEnabled = call.hasArgument("noiseSuppressionEnabled")
                ? call.argument("noiseSuppressionEnabled") : true;
        // Calculate buffer size (20ms frames)
        int frameSize = (sampleRate * 20) / 1000; // samples per 20ms
        bufferSize = frameSize * 2; // 16-bit = 2 bytes per sample

        int minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat);
        if (bufferSize < minBuffer) {
            bufferSize = minBuffer;
        }

        Log.i(TAG, String.format(
                "Initialized: sampleRate=%d, bufferSize=%d, aec=%b, ns=%b",
                sampleRate, bufferSize, aecEnabled, noiseSuppressionEnabled
        ));

        result.success(true);
    }

    private void startSessionKeepAlive() {
        if (applicationContext == null) return;
        Intent intent = new Intent(applicationContext, SnailSessionService.class);
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            applicationContext.startForegroundService(intent);
        } else {
            applicationContext.startService(intent);
        }
    }

    private void stopSessionKeepAlive() {
        if (applicationContext != null) {
            applicationContext.stopService(
                    new Intent(applicationContext, SnailSessionService.class));
        }
    }

    private void handlePlayPcm16(MethodCall call, Result result) {
        try {
            java.util.List<Integer> values = call.argument("bytes");
            Integer requestedRate = call.argument("sampleRate");
            int outputRate = requestedRate == null ? 24000 : requestedRate;
            if (values == null || values.isEmpty()) { result.success(null); return; }
            byte[] bytes = new byte[values.size()];
            for (int i = 0; i < values.size(); i++) bytes[i] = (byte) (values.get(i) & 0xff);
            ensureCommunicationMode();
            String output = call.argument("output") == null ? "default" : (String) call.argument("output");
            // VOICE_CALL is routed to the quiet earpiece by several Android
            // vendors even after setSpeakerphoneOn(true). For the normal
            // no-headset conversation mode choose the built-in speaker
            // explicitly, including a matching STREAM_MUSIC AudioTrack.
            if ("default".equals(output)) {
                // Android can report the communication device as speaker
                // while Bluetooth A2DP is the active media output. Prefer
                // the actual media device list for PCM session playback.
                output = findOutputDevice("headset") != null ? "headset" : "speaker";
            }
            applyPlaybackRoute(output);
            if ("speaker".equals(output)) amplifyPcm16InPlace(bytes, 1.8);
            ensurePlaybackTrack(outputRate, bytes.length, output);
            Log.d(TAG, "Playing " + bytes.length + " PCM bytes at " + outputRate
                    + "Hz via " + output + "; route=" + activeOutputRoute());
            long durationMs = Math.max(20L, (bytes.length * 1000L) / (outputRate * 2L));
            // Hardware AEC handles the steady-state echo. Drop only a short
            // tail to prevent queued frames from leaking across chunk edges.
            suppressCaptureUntilMs = Math.max(suppressCaptureUntilMs, System.currentTimeMillis() + durationMs + 100L);
            synchronized (this) {
                playbackTrack.write(bytes, 0, bytes.length, AudioTrack.WRITE_BLOCKING);
            }
            result.success(null);
        } catch (Exception e) {
            result.error("PLAYBACK_ERROR", e.getMessage(), null);
        }
    }

    /** Short local diagnostic tone. It never opens the microphone or network. */
    private void handlePlayTestTone(Result result) {
        new Thread(() -> {
            try {
                final int rate = 24000;
                final int captureRate = 16000;
                int captureBuffer = AudioRecord.getMinBufferSize(captureRate,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                AudioRecord loopback = new AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION,
                        captureRate, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(captureBuffer, 4096));
                loopback.startRecording();
                final int samples = rate / 2;
                byte[] tone = new byte[samples * 2];
                for (int i = 0; i < samples; i++) {
                    short value = (short) (Math.sin(2.0 * Math.PI * 660.0 * i / rate) * 26000.0);
                    tone[i * 2] = (byte) (value & 0xff);
                    tone[i * 2 + 1] = (byte) ((value >> 8) & 0xff);
                }
                ensureCommunicationMode();
                synchronized (this) {
                    ensurePlaybackTrack(rate, tone.length, "speaker");
                    Log.d(TAG, "Playing local speaker test tone; route=" + activeOutputRoute());
                    playbackTrack.write(tone, 0, tone.length, AudioTrack.WRITE_BLOCKING);
                }
                byte[] captured = new byte[captureRate / 2];
                int read = loopback.read(captured, 0, captured.length);
                loopback.stop();
                loopback.release();
                long energy = 0;
                int count = Math.max(0, read / 2);
                for (int i = 0; i < count * 2; i += 2) {
                    int sample = (short) ((captured[i] & 0xff) | (captured[i + 1] << 8));
                    energy += (long) sample * sample;
                }
                long rms = count == 0 ? 0 : Math.round(Math.sqrt((double) energy / count));
                Log.i(TAG, "Speaker loopback test: rms=" + rms + ", samples=" + count
                        + ", route=" + activeOutputRoute());
                mainHandler.post(() -> result.success(true));
            } catch (Exception e) {
                mainHandler.post(() -> result.error("TEST_TONE_ERROR", e.getMessage(), null));
            }
        }, "SnailTestTone").start();
    }

    private void ensureCommunicationMode() {
        if (audioManager == null || communicationModeActive) return;
        headsetRouteActive = isHeadsetConnected();
        previousAudioMode = audioManager.getMode();
        audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            // setSpeakerphoneOn alone is ignored by several Android 12+
            // vendors. Explicitly select only a device accepted by the
            // communication API. Bluetooth A2DP is a media route, not a
            // communication route, and selecting it here silently leaves
            // several Xiaomi devices on the quiet earpiece.
            android.media.AudioDeviceInfo target = headsetRouteActive
                    ? findCommunicationOutputDevice("headset")
                    : findCommunicationOutputDevice("speaker");
            if (target != null) audioManager.setCommunicationDevice(target);
        }
        audioManager.setSpeakerphoneOn(!headsetRouteActive);
        communicationModeActive = true;
        requestPlaybackFocus();
        Log.i(TAG, "Communication audio mode enabled; headset=" + headsetRouteActive
                + ", route=" + activeOutputRoute());
    }

    /** Keep Android's media policy from classifying translated speech as background audio. */
    private void requestPlaybackFocus() {
        if (audioManager == null) return;
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            playbackFocusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build())
                    .setOnAudioFocusChangeListener(focusChange -> { })
                    .build();
            audioManager.requestAudioFocus(playbackFocusRequest);
        } else {
            audioManager.requestAudioFocus(null, AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK);
        }
    }

    private boolean isHeadsetConnected() {
        if (audioManager == null) return false;
        // A Bluetooth A2DP proxy can remain available even when the phone is
        // actually using its earpiece/speaker. It is not proof of an active
        // headset route, so do not disable the no-headset echo guard for it.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            android.media.AudioDeviceInfo communicationDevice = audioManager.getCommunicationDevice();
            if (communicationDevice != null) {
                int type = communicationDevice.getType();
                return type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                        || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                        || type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET;
            }
        }
        if (audioManager.isWiredHeadsetOn() || audioManager.isBluetoothScoOn()) return true;
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            for (android.media.AudioDeviceInfo device : audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                int type = device.getType();
                if (type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                        || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                        || type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET) return true;
            }
        }
        return false;
    }

    private String activeOutputRoute() {
        if (audioManager == null) return "unknown";
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            android.media.AudioDeviceInfo device = audioManager.getCommunicationDevice();
            if (device != null) return device.getType() + ":" + device.getProductName();
        }
        return audioManager.isBluetoothScoOn() ? "bluetooth_sco"
                : (audioManager.isWiredHeadsetOn() ? "wired" : "speaker_or_earpiece");
    }

    private java.util.Map<String, Object> audioDiagnostics() {
        java.util.Map<String, Object> diagnostics = new java.util.HashMap<>();
        diagnostics.put("headsetConnected", isHeadsetConnected());
        diagnostics.put("outputRoute", activeOutputRoute());
        diagnostics.put("aecAvailable", AcousticEchoCanceler.isAvailable());
        diagnostics.put("noiseSuppressorAvailable", NoiseSuppressor.isAvailable());
        diagnostics.put("aecActive", (aec != null && aec.getEnabled())
                || (standalonePhoneAec != null && standalonePhoneAec.getEnabled())
                || (standaloneHeadsetAec != null && standaloneHeadsetAec.getEnabled()));
        diagnostics.put("noiseSuppressionActive", (noiseSuppressor != null && noiseSuppressor.getEnabled())
                || (standalonePhoneNs != null && standalonePhoneNs.getEnabled())
                || (standaloneHeadsetNs != null && standaloneHeadsetNs.getEnabled()));
        diagnostics.put("capturing", isCapturing || standaloneCapturing);
        diagnostics.put("standaloneHeadsetCapture", standaloneHasHeadset);
        return diagnostics;
    }

    /** Returns the stable Android-Keystore public key used for device identity. */
    private String getDevicePublicKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (!keyStore.containsAlias(DEVICE_KEY_ALIAS)) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance(
                    "EC", "AndroidKeyStore");
            generator.initialize(new android.security.keystore.KeyGenParameterSpec.Builder(
                    DEVICE_KEY_ALIAS,
                    android.security.keystore.KeyProperties.PURPOSE_SIGN
                            | android.security.keystore.KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                    .setDigests(android.security.keystore.KeyProperties.DIGEST_SHA256)
                    .build());
            generator.generateKeyPair();
        }
        java.security.cert.Certificate certificate = keyStore.getCertificate(DEVICE_KEY_ALIAS);
        if (certificate == null) throw new IllegalStateException("Device public key unavailable");
        return Base64.encodeToString(certificate.getPublicKey().getEncoded(), Base64.NO_WRAP);
    }

    private String signDevicePayload(String payload) throws Exception {
        getDevicePublicKey();
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        PrivateKey privateKey = (PrivateKey) keyStore.getKey(DEVICE_KEY_ALIAS, null);
        if (privateKey == null) throw new IllegalStateException("Device private key unavailable");
        Signature signature = Signature.getInstance("SHA256withECDSA");
        signature.initSign(privateKey);
        signature.update(payload.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        return Base64.encodeToString(signature.sign(), Base64.NO_WRAP);
    }

    /** Applies a conservative speaker gain while preventing 16-bit overflow. */
    private static void amplifyPcm16InPlace(byte[] pcm, double gain) {
        for (int i = 0; i + 1 < pcm.length; i += 2) {
            int sample = (short) ((pcm[i] & 0xff) | (pcm[i + 1] << 8));
            int amplified = (int) Math.round(sample * gain);
            if (amplified > Short.MAX_VALUE) amplified = Short.MAX_VALUE;
            if (amplified < Short.MIN_VALUE) amplified = Short.MIN_VALUE;
            pcm[i] = (byte) (amplified & 0xff);
            pcm[i + 1] = (byte) ((amplified >> 8) & 0xff);
        }
    }

    private synchronized void ensurePlaybackTrack(int rate, int bytesPerChunk, String output) {
        if (playbackTrack != null && playbackRate == rate && playbackOutput.equals(output)
                && playbackTrack.getState() == AudioTrack.STATE_INITIALIZED) return;
        stopPlayback();
        playbackRate = rate;
        playbackOutput = output;
        // Translated speech must be audible through wired, USB and Bluetooth
        // headphones. STREAM_VOICE_CALL commonly stays on the earpiece when a
        // Bluetooth A2DP device is connected; media audio follows the user's
        // active headset route while capture/AEC remains in communication mode.
        int stream = AudioManager.STREAM_MUSIC;
        int min = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
        // Keep a small realtime queue. A long diagnostic chunk used to expand
        // this to a four-second buffer, so a 0.5 s test tone never became
        // audible before playback underrun/restart.
        int targetBytes = Math.max(bytesPerChunk * 2, rate / 20);
        int maxRealtimeBytes = rate / 4; // 125 ms of PCM16 at the output rate
        int capacity = Math.max(min, Math.min(targetBytes, maxRealtimeBytes));
        playbackTrack = new AudioTrack(
                stream,
                rate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                capacity,
                AudioTrack.MODE_STREAM
        );
        if (playbackTrack.getState() != AudioTrack.STATE_INITIALIZED) {
            stopPlayback();
            throw new IllegalStateException("Voice communication playback unavailable");
        }
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            android.media.AudioDeviceInfo preferred = findOutputDevice(output);
            if (preferred != null) playbackTrack.setPreferredDevice(preferred);
        }
        playbackTrack.setVolume(1.0f);
        playbackTrack.play();
    }

    /** Re-apply the user-selected media route for every chunk. The communication
     * device may be reset to the speaker when Android recreates the Bluetooth
     * SCO/A2DP route, so doing this only once during capture is insufficient. */
    private void applyPlaybackRoute(String output) {
        if (audioManager == null) return;
        if ("headset".equals(output)) {
            android.media.AudioDeviceInfo mediaHeadset = findOutputDevice("headset");
            if (mediaHeadset != null && mediaHeadset.getType() == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) {
                // A2DP is a media route, not a communication route. Keeping
                // MODE_IN_COMMUNICATION here makes some vendor drivers reject
                // AudioTrack writes with -22 and fall back to the speaker.
                audioManager.setMode(AudioManager.MODE_NORMAL);
                audioManager.setSpeakerphoneOn(false);
                Log.i(TAG, "Playback route selected: Bluetooth A2DP " + mediaHeadset.getProductName());
            }
        } else if ("speaker".equals(output)) {
            audioManager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            audioManager.setSpeakerphoneOn(true);
        }
    }

    private android.media.AudioDeviceInfo findOutputDevice(String output) {
        if (audioManager == null || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) return null;
        android.media.AudioDeviceInfo speaker = null;
        for (android.media.AudioDeviceInfo device : audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            int type = device.getType();
            if (type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) speaker = device;
            if ("speaker".equals(output) && type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) return device;
            if ("headset".equals(output) && (type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
                    || type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                    || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                    || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    || type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET)) return device;
        }
        return "speaker".equals(output) ? speaker : null;
    }

    private android.media.AudioDeviceInfo findCommunicationOutputDevice(String output) {
        if (audioManager == null || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return null;
        for (android.media.AudioDeviceInfo device : audioManager.getAvailableCommunicationDevices()) {
            int type = device.getType();
            if ("speaker".equals(output) && type == android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                return device;
            }
            if ("headset".equals(output) && (type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
                    || type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES
                    || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                    || type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET)) {
                return device;
            }
        }
        return null;
    }

    private synchronized void stopPlayback() {
        if (playbackTrack != null) {
            try { playbackTrack.pause(); } catch (Exception ignored) {}
            try { playbackTrack.flush(); } catch (Exception ignored) {}
            try { playbackTrack.release(); } catch (Exception ignored) {}
            playbackTrack = null;
        }
    }

    private void restoreAudioMode() {
        if (audioManager != null && communicationModeActive) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O && playbackFocusRequest != null) {
                audioManager.abandonAudioFocusRequest(playbackFocusRequest);
                playbackFocusRequest = null;
            } else {
                audioManager.abandonAudioFocus(null);
            }
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice();
            }
            audioManager.setSpeakerphoneOn(false);
            audioManager.setMode(previousAudioMode);
            communicationModeActive = false;
        }
    }

    private void handleStartCapture(Result result) {
        if (isCapturing) {
            result.success(true);
            return;
        }

        try {
            ensureCommunicationMode();
            audioRecord = new AudioRecord(
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION, // Best for AEC
                    sampleRate,
                    channelConfig,
                    audioFormat,
                    bufferSize * 4 // Larger buffer for stability
            );

            if (audioRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                result.error("AUDIO_INIT_FAILED", "AudioRecord not initialized", null);
                return;
            }

            // ── AEC ──────────────────────────────────────────────────
            int audioSessionId = audioRecord.getAudioSessionId();
            if (aecEnabled && AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(audioSessionId);
                if (aec != null) {
                    aec.setEnabled(true);
                    Log.i(TAG, "AEC enabled on session " + audioSessionId);
                } else {
                    Log.w(TAG, "AEC creation failed");
                }
            } else {
                Log.i(TAG, "AEC not available or disabled");
            }

            // ── Noise Suppression ────────────────────────────────────
            if (noiseSuppressionEnabled && NoiseSuppressor.isAvailable()) {
                noiseSuppressor = NoiseSuppressor.create(audioSessionId);
                if (noiseSuppressor != null) {
                    noiseSuppressor.setEnabled(true);
                    Log.i(TAG, "Noise Suppression enabled");
                } else {
                    Log.w(TAG, "Noise Suppression creation failed");
                }
            } else {
                Log.i(TAG, "Noise Suppression not available or disabled");
            }

            // Start recording
            audioRecord.startRecording();
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M
                    && "headset".equals(preferredInput)) {
                android.media.AudioDeviceInfo input = findInputHeadset();
                if (input != null) audioRecord.setPreferredDevice(input);
            }
            isCapturing = true;

            // Start capture thread
            captureThread = new Thread(this::captureLoop, "SnailAudioCapture");
            captureThread.start();

            Log.i(TAG, "Capture started");
            result.success(true);

        } catch (SecurityException e) {
            result.error("PERMISSION_DENIED", "RECORD_AUDIO permission not granted", e.getMessage());
        } catch (Exception e) {
            result.error("CAPTURE_ERROR", e.getMessage(), null);
        }
    }

    private void handleStartStandaloneCapture(MethodCall call, Result result) {
        if (standaloneCapturing) { result.success(true); return; }
        int rate = call.hasArgument("sampleRate") ? (Integer) call.argument("sampleRate") : 16000;
        int min = AudioRecord.getMinBufferSize(rate, channelConfig, audioFormat);
        try {
            // PHONE uses the near-field handset microphone; HEADSET uses the
            // communication input route selected by Android/Bluetooth.
            phoneRecord = new AudioRecord(MediaRecorder.AudioSource.MIC, rate, channelConfig, audioFormat, Math.max(min * 2, 2048));
            if (phoneRecord.getState() != AudioRecord.STATE_INITIALIZED) {
                stopStandaloneCapture();
                result.error("PHONE_AUDIO_UNAVAILABLE", "Android konnte das Handy-Mikrofon nicht öffnen", null);
                return;
            }
            // Do not open a second recorder against the phone microphone when
            // no headset route is active. Several Android drivers report that
            // recorder as initialized, then crash or duplicate the phone mic.
            if (hasHeadsetInputRoute()) {
                try {
                    headsetRecord = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate, channelConfig, audioFormat, Math.max(min * 2, 2048));
                    standaloneHasHeadset = headsetRecord.getState() == AudioRecord.STATE_INITIALIZED;
                    if (standaloneHasHeadset && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                        android.media.AudioDeviceInfo input = findInputHeadset();
                        if (input != null) headsetRecord.setPreferredDevice(input);
                    }
                } catch (Exception ignored) {
                    headsetRecord = null;
                    standaloneHasHeadset = false;
                }
            } else {
                headsetRecord = null;
                standaloneHasHeadset = false;
            }
            phoneRecord.startRecording();
            if (standaloneHasHeadset) headsetRecord.startRecording();
            if (aecEnabled) {
                standalonePhoneAec = AcousticEchoCanceler.create(phoneRecord.getAudioSessionId());
                if (standalonePhoneAec != null) standalonePhoneAec.setEnabled(true);
                if (standaloneHasHeadset) {
                    standaloneHeadsetAec = AcousticEchoCanceler.create(headsetRecord.getAudioSessionId());
                    if (standaloneHeadsetAec != null) standaloneHeadsetAec.setEnabled(true);
                }
            }
            if (noiseSuppressionEnabled) {
                standalonePhoneNs = NoiseSuppressor.create(phoneRecord.getAudioSessionId());
                if (standalonePhoneNs != null) standalonePhoneNs.setEnabled(true);
                if (standaloneHasHeadset) {
                    standaloneHeadsetNs = NoiseSuppressor.create(headsetRecord.getAudioSessionId());
                    if (standaloneHeadsetNs != null) standaloneHeadsetNs.setEnabled(true);
                }
            }
            Log.i(TAG, "Standalone capture started; phone=true, headset=" + standaloneHasHeadset
                    + ", aec=" + (standalonePhoneAec != null || standaloneHeadsetAec != null)
                    + ", ns=" + (standalonePhoneNs != null || standaloneHeadsetNs != null));
            standaloneCapturing = true;
            standalonePhoneThread = new Thread(() -> standaloneLoop(rate, true), "SnailStandalonePhoneCapture");
            standalonePhoneThread.start();
            if (standaloneHasHeadset) {
                standaloneHeadsetThread = new Thread(() -> standaloneLoop(rate, false), "SnailStandaloneHeadsetCapture");
                standaloneHeadsetThread.start();
            }
            result.success(true);
        } catch (Exception e) {
            stopStandaloneCapture();
            result.error("DUAL_AUDIO_ERROR", e.getMessage(), null);
        }
    }

    private android.media.AudioDeviceInfo findInputHeadset() {
        if (audioManager == null || android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) return null;
        for (android.media.AudioDeviceInfo device : audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
            int type = device.getType();
            if (type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
                    || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    || type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET) return device;
        }
        return null;
    }

    private boolean hasHeadsetInputRoute() {
        if (audioManager == null) return false;
        if (audioManager.isWiredHeadsetOn() || audioManager.isBluetoothScoOn()) return true;
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            for (android.media.AudioDeviceInfo device : audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
                int type = device.getType();
                if (type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET
                        || type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        || type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET) return true;
            }
        }
        return false;
    }

    private void standaloneLoop(int rate, boolean phoneSource) {
        byte[] frame = new byte[640];
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);
        AudioRecord record = phoneSource ? phoneRecord : headsetRecord;
        while (standaloneCapturing && record != null) {
            int bytesRead = record.read(frame, 0, frame.length);
            if (bytesRead <= 0 || standaloneEventSink == null) continue;
            // Copy before posting to the Flutter thread. The capture loop
            // reuses this buffer on the next iteration.
            final byte[] frameSnapshot = java.util.Arrays.copyOf(frame, bytesRead);
            final String source = phoneSource ? "phone" : "headset";
            mainHandler.post(() -> {
                EventChannel.EventSink sink = standaloneEventSink;
                if (sink == null) return;
                sink.success(new java.util.HashMap<String, Object>() {{
                    put("source", source);
                    put("bytes", frameSnapshot);
                    put("sampleRate", rate);
                }});
            });
        }
    }

    private void stopStandaloneCapture() {
        standaloneCapturing = false;
        if (standalonePhoneThread != null) { standalonePhoneThread.interrupt(); standalonePhoneThread = null; }
        if (standaloneHeadsetThread != null) { standaloneHeadsetThread.interrupt(); standaloneHeadsetThread = null; }
        if (phoneRecord != null) { try { phoneRecord.stop(); } catch (Exception ignored) {} phoneRecord.release(); phoneRecord = null; }
        if (headsetRecord != null) { try { headsetRecord.stop(); } catch (Exception ignored) {} headsetRecord.release(); headsetRecord = null; }
        if (standalonePhoneAec != null) { standalonePhoneAec.release(); standalonePhoneAec = null; }
        if (standaloneHeadsetAec != null) { standaloneHeadsetAec.release(); standaloneHeadsetAec = null; }
        if (standalonePhoneNs != null) { standalonePhoneNs.release(); standalonePhoneNs = null; }
        if (standaloneHeadsetNs != null) { standaloneHeadsetNs.release(); standaloneHeadsetNs = null; }
        standaloneHasHeadset = false;
    }

    private void handleStopCapture(Result result) {
        stopCapture();
        result.success(null);
    }

    // ── Capture Loop ──────────────────────────────────────────────────

    private void captureLoop() {
        ByteBuffer buffer = ByteBuffer.allocateDirect(bufferSize);
        byte[] bytes = new byte[bufferSize];

        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO);

        while (isCapturing && audioRecord != null && !Thread.interrupted()) {
            buffer.clear();
            int read = audioRecord.read(buffer, bufferSize);

            if (read > 0) {
                buffer.get(bytes, 0, read);

                // Drop frames while translated playback (and its acoustic
                // tail) is active. This prevents queued EventChannel frames
                // from reaching the provider after the Dart-side gate ends.
                if (!isHeadsetConnected() && System.currentTimeMillis() < suppressCaptureUntilMs) {
                    continue;
                }

                // Send to Flutter
                if (eventSink != null) {
                    byte[] data = new byte[read];
                    System.arraycopy(bytes, 0, data, 0, read);
                    mainHandler.post(() -> {
                        EventChannel.EventSink sink = eventSink;
                        if (sink != null) sink.success(data);
                    });
                }
            } else if (read == AudioRecord.ERROR_INVALID_OPERATION) {
                Log.e(TAG, "AudioRecord ERROR_INVALID_OPERATION");
                break;
            } else if (read == AudioRecord.ERROR_BAD_VALUE) {
                Log.e(TAG, "AudioRecord ERROR_BAD_VALUE");
                break;
            }
        }
    }

    private void stopCapture() {
        isCapturing = false;

        if (captureThread != null) {
            captureThread.interrupt();
            try {
                captureThread.join(500);
            } catch (InterruptedException e) {
                // ignore
            }
            captureThread = null;
        }

        if (aec != null) {
            aec.setEnabled(false);
            aec.release();
            aec = null;
        }

        if (noiseSuppressor != null) {
            noiseSuppressor.setEnabled(false);
            noiseSuppressor.release();
            noiseSuppressor = null;
        }

        if (audioRecord != null) {
            try {
                if (audioRecord.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) {
                    audioRecord.stop();
                }
            } catch (Exception e) {
                // ignore
            }
            audioRecord.release();
            audioRecord = null;
        }

        Log.i(TAG, "Capture stopped");
    }

    // ── Event Channel (Audio Stream) ──────────────────────────────────

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        this.eventSink = events;
        Log.i(TAG, "Event listener attached");
    }

    @Override
    public void onCancel(Object arguments) {
        this.eventSink = null;
        Log.i(TAG, "Event listener detached");
    }
}
