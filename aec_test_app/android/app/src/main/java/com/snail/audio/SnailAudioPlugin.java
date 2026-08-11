package com.snail.audio;

import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.NoiseSuppressor;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.util.Log;

import androidx.annotation.NonNull;

import java.nio.ByteBuffer;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

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
public class SnailAudioPlugin implements FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private static final String TAG = "SnailAudio";
    private static final String METHOD_CHANNEL = "com.snail.audio/method";
    private static final String EVENT_CHANNEL = "com.snail.audio/stream";

    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private EventChannel.EventSink eventSink;

    // Audio
    private AudioRecord audioRecord;
    private AcousticEchoCanceler aec;
    private NoiseSuppressor noiseSuppressor;
    private Thread captureThread;
    private volatile boolean isCapturing = false;

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
        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL);
        methodChannel.setMethodCallHandler(this);

        eventChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL);
        eventChannel.setStreamHandler(this);

        Log.i(TAG, "SnailAudioPlugin attached");
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        stopCapture();
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
            case "startCapture":
                handleStartCapture(result);
                break;
            case "stopCapture":
                handleStopCapture(result);
                break;
            case "isAecAvailable":
                result.success(AcousticEchoCanceler.isAvailable());
                break;
            case "isNoiseSuppressorAvailable":
                result.success(NoiseSuppressor.isAvailable());
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
            default:
                result.notImplemented();
        }
    }

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

    private void handleStartCapture(Result result) {
        if (isCapturing) {
            result.success(true);
            return;
        }

        try {
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

                // Send to Flutter
                if (eventSink != null) {
                    byte[] data = new byte[read];
                    System.arraycopy(bytes, 0, data, 0, read);
                    eventSink.success(data);
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
