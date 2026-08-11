"""Word Error Rate (WER) Berechnung.

Nutzt jiwer (Levenshtein-basiert auf Wort-Ebene).
"""

from jiwer import wer as jiwer_wer


def calculate_wer(reference: str, hypothesis: str) -> float:
    """Berechnet Word Error Rate (0.0 = perfekt, 1.0 = komplett falsch).

    Normalisiert: lowercase, strip, collapse whitespace.

    Args:
        reference: Referenz-Transkript (Ground Truth).
        hypothesis: STT-Transkript (Hypothese).

    Returns:
        WER als float (0.0–1.0).
    """
    if not reference.strip():
        return 1.0 if hypothesis.strip() else 0.0

    ref_norm = reference.strip().lower()
    hyp_norm = hypothesis.strip().lower()

    return jiwer_wer(ref_norm, hyp_norm)
