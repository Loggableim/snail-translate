"""Übersetzungs-API-Clients.

Unterstützt:
- Morph DeepSeek V4 Flash (günstig, $0.14/1M in, 150 tok/s)
- Groq LLM (Fallback, via Chat API)
- DeepL Free/Pro (optional)
"""

import time
from dataclasses import dataclass

import requests


@dataclass
class TranslationResult:
    translated_text: str
    latency_ms: float
    api: str  # "morph" | "groq" | "deepl_free" | "deepl_pro"


def translate_morph(
    text: str,
    api_key: str,
    source_lang: str = "de",
    target_lang: str = "en",
    model: str = "morph-dsv4flash",
) -> TranslationResult:
    """Morph DeepSeek V4 Flash Übersetzung.

    $0.14/1M Input, $0.28/1M Output, ~150 tok/s.
    Extrem günstig für Übersetzungen.

    Args:
        text: Zu übersetzender Text.
        api_key: Morph API-Key.
        source_lang: Quellsprache (default: "de").
        target_lang: Zielsprache (default: "en").
        model: Morph-Modell (default: morph-dsv4flash).

    Returns:
        TranslationResult mit übersetztem Text und Latenz.
    """
    lang_names = {
        "de": "German", "en": "English", "fr": "French", "es": "Spanish",
        "it": "Italian", "ja": "Japanese", "ko": "Korean", "zh": "Chinese",
    }
    src_name = lang_names.get(source_lang, source_lang)
    tgt_name = lang_names.get(target_lang, target_lang)

    url = "https://api.morphllm.com/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    f"You are a translator. Translate the user's text from "
                    f"{src_name} to {tgt_name}. Return ONLY the translation, "
                    f"no explanations, no quotes, no additional text."
                ),
            },
            {"role": "user", "content": text},
        ],
        "temperature": 0.1,
        "max_tokens": 1024,
    }

    t0 = time.monotonic()
    resp = requests.post(url, headers=headers, json=payload)
    t1 = time.monotonic()

    resp.raise_for_status()
    result = resp.json()
    translated = result["choices"][0]["message"]["content"].strip()

    return TranslationResult(
        translated_text=translated,
        latency_ms=(t1 - t0) * 1000,
        api="morph",
    )


def translate_groq(
    text: str,
    api_key: str,
    source_lang: str = "de",
    target_lang: str = "en",
    model: str = "openai/gpt-oss-20b",
) -> TranslationResult:
    """Groq LLM Übersetzung via Chat API (Fallback).

    Args:
        text: Zu übersetzender Text.
        api_key: Groq API-Key.
        source_lang: Quellsprache (default: "de").
        target_lang: Zielsprache (default: "en").
        model: Groq-Modell (default: openai/gpt-oss-20b).

    Returns:
        TranslationResult mit übersetztem Text und Latenz.
    """
    lang_names = {
        "de": "German", "en": "English", "fr": "French", "es": "Spanish",
        "it": "Italian", "ja": "Japanese", "ko": "Korean", "zh": "Chinese",
    }
    src_name = lang_names.get(source_lang, source_lang)
    tgt_name = lang_names.get(target_lang, target_lang)

    url = "https://api.groq.com/openai/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    f"You are a translator. Translate the user's text from "
                    f"{src_name} to {tgt_name}. Return ONLY the translation, "
                    f"no explanations, no quotes, no additional text."
                ),
            },
            {"role": "user", "content": text},
        ],
        "temperature": 0.1,
        "max_tokens": 1024,
    }

    t0 = time.monotonic()
    resp = requests.post(url, headers=headers, json=payload)
    t1 = time.monotonic()

    resp.raise_for_status()
    result = resp.json()
    translated = result["choices"][0]["message"]["content"].strip()

    return TranslationResult(
        translated_text=translated,
        latency_ms=(t1 - t0) * 1000,
        api="groq",
    )


def translate_deepl(
    text: str,
    api_key: str,
    source_lang: str = "de",
    target_lang: str = "en",
    pro: bool = False,
) -> TranslationResult:
    """DeepL API (Free oder Pro) — optional.

    Free: api-free.deepl.com — 500k Zeichen/Monat kostenlos.
    Pro: api.deepl.com — bezahlt.
    """
    base_url = "https://api.deepl.com" if pro else "https://api-free.deepl.com"
    url = f"{base_url}/v2/translate"

    headers = {"Authorization": f"DeepL-Auth-Key {api_key}"}
    data = {
        "text": [text],
        "source_lang": source_lang.upper(),
        "target_lang": target_lang.upper(),
    }

    t0 = time.monotonic()
    resp = requests.post(url, headers=headers, data=data)
    t1 = time.monotonic()

    resp.raise_for_status()
    result = resp.json()
    translated = result["translations"][0]["text"]

    return TranslationResult(
        translated_text=translated,
        latency_ms=(t1 - t0) * 1000,
        api="deepl_pro" if pro else "deepl_free",
    )
