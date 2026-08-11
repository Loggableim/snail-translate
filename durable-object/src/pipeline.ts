/**
 * Audio pipeline proxy for Durable Object.
 *
 * Routes audio through STT → MT → TTS APIs.
 * API keys are injected server-side (never exposed to clients).
 *
 * Free tier:  Groq Whisper → DeepL Free → Google Cloud TTS
 * Paid tier:  Deepgram Nova-2 → DeepL Pro → fish.audio
 */

// ── Types ────────────────────────────────────────────────────────────

interface PipelineConfig {
  sttApiKey: string;
  sttUrl: string;
  mtApiKey: string;
  mtUrl: string;
  ttsApiKey: string;
  ttsUrl: string;
}

// ── API Key Access ────────────────────────────────────────────────────

function getApiKeys(tier: "free" | "paid"): PipelineConfig {
  // Keys are injected via environment/secrets in the DO
  const env = globalThis as any;

  if (tier === "free") {
    return {
      sttApiKey: env.GROQ_API_KEY || "",
      sttUrl: "https://api.groq.com/openai/v1/audio/transcriptions",
      mtApiKey: env.DEEPL_API_KEY || "",
      mtUrl: "https://api-free.deepl.com/v2/translate",
      ttsApiKey: env.GOOGLE_APPLICATION_CREDENTIALS || "",
      ttsUrl: "https://texttospeech.googleapis.com/v1/text:synthesize",
    };
  }

  return {
    sttApiKey: env.DEEPGRAM_API_KEY || "",
    sttUrl: "https://api.deepgram.com/v1/listen",
    mtApiKey: env.DEEPL_API_KEY || "",
    mtUrl: "https://api.deepl.com/v2/translate",
    ttsApiKey: env.FISHAUDIO_API_KEY || "",
    ttsUrl: "https://api.fish.audio/v1/tts",
  };
}

// ── STT (Speech-to-Text) ─────────────────────────────────────────────

async function speechToText(
  audio: number[],
  sourceLang: string,
  config: PipelineConfig
): Promise<string> {
  const audioBuffer = new Uint8Array(audio);

  // Groq Whisper (Free tier)
  if (config.sttUrl.includes("groq")) {
    const formData = new FormData();
    formData.append("file", new Blob([audioBuffer], { type: "audio/wav" }), "audio.wav");
    formData.append("model", "whisper-large-v3");
    formData.append("language", sourceLang);

    const resp = await fetch(config.sttUrl, {
      method: "POST",
      headers: { Authorization: `Bearer ${config.sttApiKey}` },
      body: formData,
    });

    if (!resp.ok) {
      throw new Error(`Groq STT error: ${resp.status}`);
    }

    const data: any = await resp.json();
    return data.text || "";
  }

  // Deepgram Nova-2 (Paid tier)
  const resp = await fetch(config.sttUrl, {
    method: "POST",
    headers: {
      Authorization: `Token ${config.sttApiKey}`,
      "Content-Type": "audio/wav",
    },
    body: audioBuffer,
  });

  if (!resp.ok) {
    throw new Error(`Deepgram STT error: ${resp.status}`);
  }

  const data: any = await resp.json();
  try {
    return data.results.channels[0].alternatives[0].transcript || "";
  } catch {
    return "";
  }
}

// ── MT (Machine Translation) ──────────────────────────────────────────

async function translateText(
  text: string,
  sourceLang: string,
  targetLang: string,
  config: PipelineConfig
): Promise<string> {
  const resp = await fetch(config.mtUrl, {
    method: "POST",
    headers: {
      Authorization: `DeepL-Auth-Key ${config.mtApiKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      text,
      source_lang: sourceLang.toUpperCase(),
      target_lang: targetLang.toUpperCase(),
    }),
  });

  if (!resp.ok) {
    throw new Error(`DeepL MT error: ${resp.status}`);
  }

  const data: any = await resp.json();
  return data.translations?.[0]?.text || text;
}

// ── TTS (Text-to-Speech) ─────────────────────────────────────────────

async function textToSpeech(
  text: string,
  targetLang: string,
  config: PipelineConfig
): Promise<Uint8Array> {
  // Google Cloud TTS (Free tier)
  if (config.ttsUrl.includes("googleapis")) {
    const resp = await fetch(config.ttsUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        input: { text },
        voice: {
          languageCode: targetLang,
          name: `${targetLang}-Standard-A`,
        },
        audioConfig: {
          audioEncoding: "MP3",
        },
      }),
    });

    if (!resp.ok) {
      throw new Error(`Google TTS error: ${resp.status}`);
    }

    const data: any = await resp.json();
    // Google returns base64-encoded audio
    const audioBytes = Uint8Array.from(atob(data.audioContent), (c) =>
      c.charCodeAt(0)
    );
    return audioBytes;
  }

  // fish.audio (Paid tier)
  const resp = await fetch(config.ttsUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.ttsApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      reference_id: "default",
      model: "s2-pro",
      text,
      format: "mp3",
    }),
  });

  if (!resp.ok) {
    throw new Error(`fish.audio TTS error: ${resp.status}`);
  }

  return new Uint8Array(await resp.arrayBuffer());
}

// ── Main Pipeline ─────────────────────────────────────────────────────

export async function processAudioPipeline(
  audio: number[],
  sourceLang: string,
  targetLang: string,
  tier: "free" | "paid"
): Promise<Uint8Array> {
  const config = getApiKeys(tier);

  // 1. STT: Audio → Text
  const transcript = await speechToText(audio, sourceLang, config);

  if (!transcript.trim()) {
    // Return silence if no speech detected
    return new Uint8Array(0);
  }

  // 2. MT: Text → Translated text
  const translation = await translateText(
    transcript,
    sourceLang,
    targetLang,
    config
  );

  // 3. TTS: Translated text → Audio
  const audioOutput = await textToSpeech(translation, targetLang, config);

  return audioOutput;
}
