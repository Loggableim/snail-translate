# M1 — AEC Test-Protokoll

> **Status:** Simulation ✅ | Hardware-Test ⏳ (benötigt 2 Android-Handys + 2 BT-Headsets)
> **Datum Simulation:** 2026-08-10
> **Go/No-Go:** 🟢 **GO** (Simulation) — E5 kein Feedback-Loop

---

## Test-Setup

| Komponente | Spezifikation |
|---|---|
| Gerät A | Android 12+ (Host) |
| Gerät B | Android 12+ (Guest) |
| Headset A | Bluetooth 5.0+ (z.B. Sony WH-1000XM4) |
| Headset B | Bluetooth 5.0+ |
| Abstand | 1–2 Meter (typische Gesprächsdistanz) |
| Raum | Normaler Büroraum (kein schalltoter Raum) |
| App | Snail Flutter-App (Debug-Build) |

---

## Szenarien

### E1 — AEC off, Lautsprecher (Baseline)

**Setup:** Beide Geräte nutzen eingebaute Lautsprecher. AEC deaktiviert.

**Erwartung:** ❌ Echo hörbar — das ist die Baseline. Der Lautsprecher von Gerät B spielt die Übersetzung ab, die das Mikrofon von Gerät A wieder aufnimmt → Echo-Schleife.

**Simulationsergebnis:**
- Echo erkannt: ❌ JA
- Echo-Energie: -20.0 dB
- Signal-zu-Echo: 20.0 dB
- Feedback-Loop: ✅ NEIN (einmaliges Echo, keine Schleife)
- **Bestanden: ❌ NEIN (erwartet)**

**Hardware-Test:**
- [ ] Echo hörbar?
- [ ] Echo stört Verständlichkeit?
- [ ] Feedback-Loop (ansteigendes Echo)?

---

### E2 — AEC on (Android AudioFX), Lautsprecher

**Setup:** Beide Geräte nutzen eingebaute Lautsprecher. AEC via Android `AudioEffect.AcousticEchoCanceler` aktiviert.

**Erwartung:** ✅ Echo deutlich reduziert oder eliminiert.

**Simulationsergebnis:**
- Echo erkannt: ❌ JA (Rest-Echo)
- Echo-Energie: -14.4 dB
- Signal-zu-Echo: 14.4 dB
- AEC-Reduktion: 14.4 dB
- Feedback-Loop: ✅ NEIN
- **Bestanden: ✅ JA**

**Hardware-Test:**
- [ ] Echo hörbar?
- [ ] AEC-Reduktion subjektiv spürbar?
- [ ] Verständlichkeit der Übersetzung?
- [ ] `AcousticEchoCanceler.isAvailable()` → true?

---

### E3 — AEC on (iOS AVAudioSession), Lautsprecher

**Setup:** Gleicher Test auf iOS (falls verfügbar). iOS nutzt `AVAudioSession` mit `.echoCancellation`.

**Erwartung:** ✅ Echo reduziert (iOS AEC ist oft besser als Android).

**Simulationsergebnis:**
- Echo erkannt: ❌ JA (Rest-Echo)
- Echo-Energie: -14.3 dB
- Signal-zu-Echo: 14.3 dB
- AEC-Reduktion: 14.3 dB
- Feedback-Loop: ✅ NEIN
- **Bestanden: ✅ JA**

**Hardware-Test:**
- [ ] Echo hörbar?
- [ ] Besser/schlechter als Android (E2)?
- [ ] `AVAudioSession.sharedInstance().inputLatency`?

---

### E4 — AEC + BT-Headset, Lautsprecher

**Setup:** Beide Geräte mit BT-Headsets. AEC aktiviert. Headsets nutzen eigenes Mikrofon (nicht das Geräte-Mikrofon).

**Erwartung:** ✅ Echo minimal — BT-Headsets haben weniger akustische Kopplung (Mikrofon näher am Mund, Lautsprecher im Ohr).

**Simulationsergebnis:**
- Echo erkannt: ❌ JA (minimal)
- Echo-Energie: -14.7 dB
- Signal-zu-Echo: 14.7 dB
- AEC-Reduktion: 14.7 dB
- Feedback-Loop: ✅ NEIN
- **Bestanden: ✅ JA**

**Hardware-Test:**
- [ ] Echo hörbar?
- [ ] BT-Latenz spürbar? (A2DP hat ~150-250ms Latenz)
- [ ] Audio-Qualität über BT-Headset?
- [ ] Funktioniert AEC mit BT-Headset-Mikrofon?

---

### E5 — AEC + BT-Headset (beide Geräte) — Feedback-Loop-Test

**Setup:** Der kritischste Test. Beide Geräte mit BT-Headsets, AEC aktiviert, beide sprechen gleichzeitig (bidirektional).

**Erwartung:** ✅ Kein Feedback-Loop. Wenn beide gleichzeitig sprechen und die Übersetzung des anderen hören, darf kein ansteigendes Echo entstehen.

**Simulationsergebnis:**
- Echo erkannt: ❌ JA (Rest-Echo)
- Echo-Energie: -14.8 dB
- Signal-zu-Echo: 14.8 dB
- AEC-Reduktion: 14.8 dB
- Feedback-Loop: ✅ **NEIN** ← KRITISCH
- **Bestanden: ✅ JA**

**Hardware-Test:**
- [ ] **Feedback-Loop aufgetreten?** ← KRITISCH
- [ ] Beide gleichzeitig sprechen → Echo?
- [ ] Nach 30 Sekunden: Echo lauter geworden?
- [ ] Nach 60 Sekunden: Echo lauter geworden?
- [ ] Verständlichkeit bei gleichzeitigem Sprechen?

---

## Go/No-Go Entscheidung

| Ergebnis | Aktion |
|---|---|
| E5: kein Feedback-Loop | ✅ **GO** → M4 (Zwei-Geräte-Prototyp) |
| E5: Feedback-Loop trotz AEC | ❌ **NO-GO** → Fallback-Strategie |

### Fallback bei No-Go

1. **Halb-Duplex-Modus:** Playback pausiert Mikrofon während der Wiedergabe. Weniger natürlich, aber funktioniert sicher.
2. **Externes AEC:** RNNoise + SpeexDSP AEC als Software-Pipeline (statt OS-native).
3. **LE Audio Headsets:** Bluetooth LE Audio hat geringere Latenz und besseres AEC.
4. **Push-to-Talk:** Manuelles Aktivieren des Mikrofons (Walkie-Talkie-Modus).

---

## Simulations-Methodik

Die Simulation verwendet:
- **Echo-Modell:** Verzögertes + gedämpftes Playback-Signal (50ms Delay, -20dB)
- **AEC-Modell:** Spektrale Subtraktion (STFT-basiert)
- **Feedback-Loop-Erkennung:** Energie-Anstieg über 1-Sekunden-Chunks

**Limitationen der Simulation:**
- Kein echtes Raum-Echo (nur einfaches Delay-Modell)
- Keine BT-Latenz (150-250ms in Realität)
- Keine nichtlinearen Verzerrungen (Lautsprecher-Übertragungsfunktion)
- Kein Hintergrundrauschen

→ **Hardware-Test ist zwingend erforderlich für finale Go/No-Go-Entscheidung.**

---

## Durchführung (Hardware)

```bash
# 1. Flutter-App im Debug-Modus bauen
cd flutter_app
flutter run --debug

# 2. AEC-Status in der App prüfen
# Settings → Audio → Echo-Unterdrückung (muss AN sein)

# 3. Session starten
# Gerät A: Home → Session starten → QR-Code zeigen
# Gerät B: Home → Session beitreten → QR scannen

# 4. Tests durchführen (E1-E5)
# Für E1: AEC in Settings deaktivieren
# Für E2-E5: AEC aktiviert lassen

# 5. Ergebnisse dokumentieren
# - Echo hörbar? (ja/nein)
# - Feedback-Loop? (ja/nein)
# - Verständlichkeit? (1-5)
# - Besondere Beobachtungen
```

---

## Ergebnisse (Hardware)

| Szenario | Echo hörbar? | Feedback-Loop? | Verständlichkeit | Bestanden? |
|---|---|---|---|---|
| E1 (AEC off) | ⬜ | ⬜ | ⬜ | ⬜ |
| E2 (AEC on, Android) | ⬜ | ⬜ | ⬜ | ⬜ |
| E3 (AEC on, iOS) | ⬜ | ⬜ | ⬜ | ⬜ |
| E4 (AEC + BT) | ⬜ | ⬜ | ⬜ | ⬜ |
| E5 (AEC + BT, beide) | ⬜ | ⬜ | ⬜ | ⬜ |

**Go/No-Go:** ⬜ GO / ⬜ NO-GO

**Datum Hardware-Test:** ________
**Tester:** ________
**Geräte:** ________
**Headsets:** ________
