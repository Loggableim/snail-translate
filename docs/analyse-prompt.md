# Analyse-Prompt: Snail Architekturkonzept

> Kopiere diesen Prompt und gib ihn einem anderen Agenten (z.B. Claude,
> GPT-4, DeepSeek) zusammen mit der Datei `ARCHITEKTUR.md`. Der Agent soll
> das Konzept kritisch reviewen und konkrete Verbesserungen vorschlagen.

---

## Aufgabe

Du bist ein erfahrener Software-Architekt mit Expertise in:
- Echtzeit-Audio-Pipelines (STT, TTS, Streaming)
- Serverless-Architekturen (Cloudflare Workers, Durable Objects)
- Mobile-Entwicklung (Flutter, React Native)
- SaaS-Monetarisierung (Free/Paid-Tiers, Auth, Subscriptions)
- Sicherheit (Key-Management, Token-basierte Architekturen)

Analysiere das beigefügte Architekturkonzept `ARCHITEKTUR.md` für das
Projekt **Snail** — einen Echtzeit-Konversationsübersetzer für zwei
Personen mit je einem Headset.

## Analyse-Schritte

Gehe das Dokument Abschnitt für Abschnitt durch und bewerte:

### 1. Zielbild & Nutzungsszenario (§1)
- Ist das Szenario klar und vollständig beschrieben?
- Fehlen wichtige Use Cases oder Randbedingungen?
- Ist das Latenz-Ziel (< 2s) realistisch?

### 2. Kern-Pipeline (§2)
- Ist die Pipeline korrekt und vollständig?
- Fehlen Schritte? Sind Schritte überflüssig?
- Ist die Entscheidung gegen Diarization (weil 2 Geräte) richtig?
- Wie würdest du die Pipeline optimieren?

### 3. Architektur-Entscheidungen (§3)
- **3a (Bluetooth-Limit):** Ist die technische Begründung korrekt?
  Übersehen wir Alternativen (LE Audio, Auracast)?
- **3b (Worker + Clerk):** Ist die Trennung von Key-Vault und Audio-Pipeline
  sauber? Ist das Session-Token-Modell sicher? Gibt es bessere Ansätze?
- **Session-Join-Flow:** Ist der Ablauf (Room-ID → QR-Code → WebSocket)
  vollständig und praktikabel? Was fehlt?

### 4. Modul-Auswahl (§4)
- Sind die gewählten APIs pro Tier sinnvoll?
- Gibt es bessere/günstigere Alternativen für Free oder Paid?
- Fehlen Bausteine (z.B. Streaming-Infrastruktur, Relay-Server)?

### 5. Latenz-Budget (§5)
- Ist das Budget realistisch mit den gewählten APIs?
- Wo siehst du die größten Latenz-Risiken?
- Wie würdest du das Budget validieren?

### 6. Technologie-Stack (§6)
- Ist Flutter die richtige Wahl für eine latenzkritische Audio-App?
- Gibt es bessere Alternativen (Kotlin Multiplatform, React Native)?
- Ist Cloudflare Worker als Key-Vault ausreichend, oder braucht es
  Durable Objects / ein klassisches Backend?

### 7. Offene Fragen (§7)
- Welche Fragen fehlen?
- Welche der genannten Fragen sind kritisch und müssen zuerst beantwortet
  werden?

### 8. Nächste Schritte (§8)
- Ist die Reihenfolge sinnvoll?
- Fehlen wichtige Schritte?
- Was würdest du anders priorisieren?

### 9. Anhang A (Quick-Tunnel)
- Ist der Alternativ-Ansatz korrekt dokumentiert?
- Gibt es Szenarien, in denen er doch sinnvoll wäre?

## Gesamtbewertung

Gib am Ende eine Gesamtbewertung mit:

1. **Stärken:** Was ist gut durchdacht? (3–5 Punkte)
2. **Schwächen:** Was ist problematisch oder unvollständig? (3–5 Punkte)
3. **Risiken:** Was sind die größten technischen oder geschäftlichen
   Risiken? (3–5 Punkte)
4. **Konkrete Verbesserungen:** Was würdest du ändern? (priorisiert,
   mit Begründung)
5. **Reifegrad:** Auf einer Skala von 1 (Idee) bis 10 (produktionsreif) —
   wo steht das Konzept und was fehlt zur nächsten Stufe?

## Format

- Antworte auf Deutsch.
- Strukturiere deine Antwort nach den Abschnitten oben.
- Sei konkret: nenne APIs, Alternativen, Zahlen.
- Sei ehrlich: wenn etwas nicht funktioniert, sag es.
- Gib priorisierte, umsetzbare Empfehlungen.
