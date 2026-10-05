"""Codes photo uniques : aléatoires, non prévisibles et faciles à recopier."""

from __future__ import annotations

import re
import secrets

# 32 caractères, sans 0/O ni 1/I : aucun caractère ambigu à la lecture ou à la saisie.
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 12
_CODE_PATTERN = re.compile(rf"^[{CODE_ALPHABET}]{{{CODE_LENGTH}}}$")
_SEPARATORS = re.compile(r"[\s\-_.]+")


def generate_code(length: int = CODE_LENGTH) -> str:
    """Code tiré par un générateur cryptographique : 32^12 = 2^60 combinaisons possibles."""
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(length))


def normalize_code(raw: str | None) -> str | None:
    """Nettoie un code saisi (« a7k4-q92x-b3lm » donne « A7K4Q92XB3LM ») ; None s'il est invalide."""
    if not raw or len(raw) > 64:
        return None
    cleaned = _SEPARATORS.sub("", raw).upper()
    return cleaned if _CODE_PATTERN.fullmatch(cleaned) else None


def is_valid_code(code: str | None) -> bool:
    """Vrai si ``code`` est déjà au format canonique (12 caractères de l'alphabet)."""
    return bool(code) and bool(_CODE_PATTERN.fullmatch(code))


def format_code(code: str, group: int = 4) -> str:
    """Version lisible avec des tirets : A7K4Q92XB3LM devient A7K4-Q92X-B3LM."""
    return "-".join(code[index : index + group] for index in range(0, len(code), group))
