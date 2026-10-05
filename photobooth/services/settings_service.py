"""Réglages modifiables depuis l'administration, stockés dans la table ``settings``.

Chaque réglage a une valeur par défaut issue du fichier .env ; l'administration
peut la surcharger sans redémarrer l'application.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from services.database import Database
from services.errors import ValidationError
from services.utils import now_iso

if TYPE_CHECKING:
    from config import Config

_RUNTIME_PREFIX = "runtime."


@dataclass(frozen=True)
class SettingSpec:
    """Description d'un réglage : type, bornes et libellé affiché dans l'administration."""

    kind: type
    label: str
    minimum: int = 0
    maximum: int = 0


RUNTIME_SETTINGS: dict[str, SettingSpec] = {
    "print_enabled": SettingSpec(bool, "Proposer l'impression"),
    "auto_print": SettingSpec(bool, "Impression automatique après chaque photo"),
    "qr_on_print": SettingSpec(bool, "QR code sur les tirages"),
    "print_max_copies": SettingSpec(int, "Copies maximum par impression", 1, 10),
    "print_limit_per_photo": SettingSpec(int, "Impressions maximum par photo (0 = illimité)", 0, 100),
    "session_timeout": SettingSpec(int, "Retour automatique à l'accueil (secondes)", 10, 600),
    "countdown_seconds": SettingSpec(int, "Durée du compte à rebours (secondes)", 1, 10),
    "preview_mirror": SettingSpec(bool, "Aperçu en miroir"),
    "sound_enabled": SettingSpec(bool, "Sons du compte à rebours"),
}


class SettingsService:
    """Lecture et écriture des réglages persistants."""

    def __init__(self, db: Database, config: Config) -> None:
        self.db = db
        self.config = config

    def get(self, key: str, default: str | None = None) -> str | None:
        row = self.db.fetch_one("SELECT value FROM settings WHERE key = ?", (key,))
        return row["value"] if row else default

    def get_int(self, key: str) -> int | None:
        value = self.get(key)
        try:
            return int(value) if value is not None else None
        except ValueError:
            return None

    def set(self, key: str, value: str) -> None:
        self.db.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            (key, value, now_iso()),
        )

    def delete(self, key: str) -> None:
        self.db.execute("DELETE FROM settings WHERE key = ?", (key,))

    @property
    def printer_name(self) -> str:
        """Imprimante choisie dans l'administration, sinon celle du fichier .env."""
        return self.get("printer_name") or self.config.printer_name

    def runtime(self, name: str) -> Any:
        """Valeur effective d'un réglage : surcharge de l'administration ou valeur du .env."""
        spec = RUNTIME_SETTINGS[name]
        default = getattr(self.config, name)
        raw = self.get(_RUNTIME_PREFIX + name)
        if raw is None:
            return default
        try:
            return _parse(spec, raw, name)
        except ValidationError:
            return default

    def runtime_values(self) -> dict[str, Any]:
        return {name: self.runtime(name) for name in RUNTIME_SETTINGS}

    def describe(self) -> list[dict[str, Any]]:
        """Liste détaillée pour le formulaire de l'administration."""
        overridden = {
            row["key"][len(_RUNTIME_PREFIX) :]
            for row in self.db.fetch_all("SELECT key FROM settings WHERE key LIKE ?", (_RUNTIME_PREFIX + "%",))
        }
        return [
            {
                "name": name,
                "label": spec.label,
                "type": "bool" if spec.kind is bool else "int",
                "min": spec.minimum if spec.kind is int else None,
                "max": spec.maximum if spec.kind is int else None,
                "value": self.runtime(name),
                "default": getattr(self.config, name),
                "overridden": name in overridden,
            }
            for name, spec in RUNTIME_SETTINGS.items()
        ]

    def update_runtime(self, values: dict[str, Any]) -> dict[str, Any]:
        """Valide puis enregistre plusieurs réglages ; rien n'est écrit si l'un d'eux est invalide."""
        parsed: dict[str, Any] = {}
        for name, raw in values.items():
            spec = RUNTIME_SETTINGS.get(name)
            if spec is None:
                raise ValidationError(f"Réglage inconnu : {name}")
            parsed[name] = _parse(spec, raw, name)
        for name, value in parsed.items():
            if value == getattr(self.config, name):
                self.delete(_RUNTIME_PREFIX + name)  # identique au .env : aucune surcharge à conserver
                continue
            stored = ("1" if value else "0") if isinstance(value, bool) else str(value)
            self.set(_RUNTIME_PREFIX + name, stored)
        return self.runtime_values()

    def reset_runtime(self) -> dict[str, Any]:
        """Revient aux valeurs du fichier .env."""
        self.db.execute("DELETE FROM settings WHERE key LIKE ?", (_RUNTIME_PREFIX + "%",))
        return self.runtime_values()


def _parse(spec: SettingSpec, raw: Any, name: str) -> Any:
    if spec.kind is bool:
        if isinstance(raw, bool):
            return raw
        text = str(raw).strip().lower()
        if text in {"1", "true", "yes", "on", "oui"}:
            return True
        if text in {"0", "false", "no", "off", "non"}:
            return False
        raise ValidationError(f"{spec.label} : valeur oui/non attendue.")
    try:
        number = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"{spec.label} : nombre entier attendu.") from exc
    if isinstance(raw, bool) or not spec.minimum <= number <= spec.maximum:
        raise ValidationError(f"{spec.label} : valeur entre {spec.minimum} et {spec.maximum} attendue ({name}).")
    return number
