import { describe, expect, it } from "vitest";
import { framePcm, framePcmEnd } from "../../durable-object/src/fish-tts";

describe("Fish TTS binary relay frames", () => {
  it("prefixes PCM with a little-endian sample rate", () => {
    const frame = framePcm(new Uint8Array([1, 2, 3, 4]), 24000);
    expect(new DataView(frame.buffer).getUint32(0, true)).toBe(24000);
    expect(Array.from(frame.slice(4))).toEqual([1, 2, 3, 4]);
  });

  it("uses a zero-rate control frame for stream end", () => {
    expect(Array.from(framePcmEnd())).toEqual([0, 0, 0, 0]);
  });
});
