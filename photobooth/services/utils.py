"""Petits utilitaires partagés : dates, slugs, tailles lisibles et écritures sûres."""

from __future__ import annotations

import logging
import os
import re
import tempfile
import unicodedata
from datetime import datetime
from pathlib import Path

logger = logging.getLogger(__name__)

_SLUG_SEPARATORS = re.compile(r"[^a-z0-9]+")
_SLUG_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$")


def now_iso() -> str:
    """Date et heure locales au format ISO 8601 avec fuseau (2027-07-05T21:30:12+02:00)."""
    return datetime.now().astimezone().isoformat(timespec="seconds")


def slugify(text: str, max_length: int = 60) -> str:
    """Transforme un texte en identifiant d'URL : « Festi'Coat 2027 » devient « festicoat-2027 »."""
    without_apostrophes = re.sub(r"['`’]", "", text or "")
    ascii_text = unicodedata.normalize("NFKD", without_apostrophes).encode("ascii", "ignore").decode("ascii")
    slug = _SLUG_SEPARATORS.sub("-", ascii_text.lower()).strip("-")
    return slug[:max_length].strip("-")


def is_valid_slug(slug: str) -> bool:
    """Un slug ne contient que des minuscules, des chiffres et des tirets (80 caractères maximum)."""
    return bool(_SLUG_PATTERN.fullmatch(slug or ""))


def human_size(num_bytes: float) -> str:
    """Taille lisible en français : 1536 -> « 1,5 Ko »."""
    size = float(num_bytes)
    for unit in ("octets", "Ko", "Mo", "Go"):
        if size < 1024:
            return f"{int(size)} {unit}" if unit == "octets" else f"{size:.1f} {unit}".replace(".", ",")
        size /= 1024
    return f"{size:.1f} To".replace(".", ",")


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Écrit un fichier via un fichier temporaire renommé : jamais de fichier à moitié écrit."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o644)
        os.replace(tmp_name, path)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise


def safe_unlink(path: Path | None) -> bool:
    """Supprime un fichier sans lever d'erreur ; renvoie True s'il a été supprimé."""
    if path is None:
        return False
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        logger.warning("Impossible de supprimer %s : %s", path, exc)
        return False


def folder_size(path: Path) -> int:
    """Taille totale (octets) des fichiers d'un dossier, sous-dossiers compris."""
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += (Path(root) / name).stat().st_size
            except OSError:
                continue
    return total
