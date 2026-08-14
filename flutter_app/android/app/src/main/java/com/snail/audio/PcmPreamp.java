package com.snail.audio;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Pure PCM soft-limiter used by the native capture/playback paths. */
final class PcmPreamp {
    private static final Map<Long, short[]> LUTS = new ConcurrentHashMap<>();

    private PcmPreamp() {}

    static void amplifyInPlace(byte[] pcm, double gain, int length) {
        long gainKey = Double.doubleToLongBits(gain);
        short[] lut = LUTS.get(gainKey);
        if (lut == null) {
            short[] candidate = buildLut(gain);
            short[] existing = LUTS.putIfAbsent(gainKey, candidate);
            lut = existing == null ? candidate : existing;
        }
        int limit = Math.min(Math.max(length, 0), pcm.length);
        for (int i = 0; i + 1 < limit; i += 2) {
            int sample = (short) ((pcm[i] & 0xff) | (pcm[i + 1] << 8));
            int amplified = lut[sample + 32768];
            pcm[i] = (byte) (amplified & 0xff);
            pcm[i + 1] = (byte) ((amplified >> 8) & 0xff);
        }
    }

    static short[] buildLut(double gain) {
        short[] lut = new short[65536];
        double denominator = Math.tanh(gain);
        for (int index = 0; index < lut.length; index++) {
            int sample = index - 32768;
            double normalized = sample / 32768.0;
            lut[index] = (short) Math.round(
                    (Math.tanh(normalized * gain) / denominator) * Short.MAX_VALUE);
        }
        return lut;
    }
}
