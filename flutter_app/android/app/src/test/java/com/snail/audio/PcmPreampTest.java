package com.snail.audio;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class PcmPreampTest {
    @Test
    public void lutMatchesReferenceAcrossFullPcmRange() {
        short[] lut = PcmPreamp.buildLut(3.0);
        double denominator = Math.tanh(3.0);
        for (int sample = Short.MIN_VALUE; sample <= Short.MAX_VALUE; sample++) {
            int expected = (int) Math.round(
                    (Math.tanh((sample / 32768.0) * 3.0) / denominator) * Short.MAX_VALUE);
            assertEquals("sample=" + sample, expected, lut[sample + 32768], 1);
        }
    }

    @Test
    public void onlyReadBytesAreModified() {
        byte[] pcm = new byte[] {0, 64, 0, 64, 0, 64};
        byte[] tail = new byte[] {pcm[4], pcm[5]};
        PcmPreamp.amplifyInPlace(pcm, 3.0, 4);
        assertEquals(tail[0], pcm[4]);
        assertEquals(tail[1], pcm[5]);
    }
}
