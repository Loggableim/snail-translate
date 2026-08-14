import { describe, expect, it } from "vitest";
import { framePcm, framePcmEnd } from "../../durable-object/src/fish-tts";

describe("Fish TTS binary relay frames", () => {
  it("keeps a 20-ms PCM frame near its binary payload size", () => {
    const pcm = new Uint8Array(960);
    const frame = framePcm(pcm, 24000, "peer_pcm");
    expect(frame.length).toBe(965);
    expect(JSON.stringify(Array.from(pcm)).length).toBeGreaterThan(frame.length);
  });

  it("prefixes PCM with a little-endian sample rate", () => {
    const frame = framePcm(new Uint8Array([1, 2, 3, 4]), 24000);
    expect(frame[0]).toBe(1);
    expect(new DataView(frame.buffer).getUint32(1, true)).toBe(24000);
    expect(Array.from(frame.slice(5))).toEqual([1, 2, 3, 4]);
  });

  it("uses a zero-rate control frame for stream end", () => {
    expect(Array.from(framePcmEnd())).toEqual([1, 0, 0, 0, 0]);
  });
});
