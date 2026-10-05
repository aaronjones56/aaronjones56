"""Organisation des fichiers : data/events/<date>-<slug>/{originals,finals,qr,thumbs,prints}/."""

from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from services.devices import DeviceStatus
from services.errors import StorageError
from services.utils import human_size

SUBFOLDERS = ("originals", "finals", "qr", "thumbs", "prints")
LOW_DISK_BYTES = 2 * 1024**3


@dataclass(frozen=True)
class EventFolder:
    """Dossier d'un événement et chemins normalisés de ses fichiers."""

    root: Path

    @property
    def originals(self) -> Path:
        return self.root / "originals"

    @property
    def finals(self) -> Path:
        return self.root / "finals"

    @property
    def qr(self) -> Path:
        return self.root / "qr"

    @property
    def thumbs(self) -> Path:
        return self.root / "thumbs"

    @property
    def prints(self) -> Path:
        return self.root / "prints"

    def ensure(self) -> EventFolder:
        for name in SUBFOLDERS:
            (self.root / name).mkdir(parents=True, exist_ok=True)
        return self

    def original_path(self, code: str, index: int = 0, total: int = 1) -> Path:
        """originals/CODE.jpg pour une photo simple, originals/CODE-1.jpg… pour une bande."""
        name = f"{code}.jpg" if total <= 1 else f"{code}-{index + 1}.jpg"
        return self.originals / name

    def original_paths(self, code: str, total: int) -> list[Path]:
        return [self.original_path(code, index, total) for index in range(max(1, total))]

    def final_path(self, code: str) -> Path:
        return self.finals / f"{code}.jpg"

    def qr_path(self, code: str) -> Path:
        return self.qr / f"{code}.png"

    def thumb_path(self, code: str) -> Path:
        return self.thumbs / f"{code}.jpg"

    def print_path(self, code: str) -> Path:
        return self.prints / f"{code}.jpg"


@dataclass(frozen=True)
class DiskUsage:
    total: int
    used: int
    free: int

    def to_dict(self) -> dict[str, Any]:
        percent = round(self.used * 100 / self.total, 1) if self.total else 0.0
        return {
            "total": self.total,
            "used": self.used,
            "free": self.free,
            "percent_used": percent,
            "total_human": human_size(self.total),
            "free_human": human_size(self.free),
        }


class Storage:
    """Racine des données (``DATA_DIR``) : événements, cache et fichiers de test."""

    def __init__(self, data_dir: Path) -> None:
        self.data_dir = data_dir
        self.events_dir = data_dir / "events"
        self.cache_dir = data_dir / "cache"
        self.tests_dir = data_dir / "tests"

    def ensure(self) -> None:
        for folder in (self.events_dir, self.cache_dir, self.tests_dir):
            folder.mkdir(parents=True, exist_ok=True)

    def event_folder(self, folder_name: str) -> EventFolder:
        return EventFolder(self.events_dir / folder_name)

    def relative(self, path: Path) -> str:
        """Chemin stocké en base, relatif à DATA_DIR : le dossier reste déplaçable."""
        return path.resolve().relative_to(self.data_dir.resolve()).as_posix()

    def absolute(self, relative_path: str) -> Path:
        """Chemin absolu d'un fichier enregistré en base, sans jamais sortir de DATA_DIR."""
        root = self.data_dir.resolve()
        candidate = (root / relative_path).resolve()
        if not candidate.is_relative_to(root):
            raise StorageError("Chemin de fichier invalide.")
        return candidate

    def disk_usage(self) -> DiskUsage:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        usage = shutil.disk_usage(self.data_dir)
        return DiskUsage(usage.total, usage.used, usage.free)

    def check(self) -> DeviceStatus:
        """Vérifie que l'on peut écrire et qu'il reste de la place."""
        try:
            self.ensure()
            probe = self.data_dir / ".write-test"
            probe.write_bytes(b"ok")
            probe.unlink()
            usage = self.disk_usage()
        except OSError as exc:
            return DeviceStatus(False, f"Écriture impossible dans {self.data_dir} : {exc.strerror or exc}")
        if usage.free < LOW_DISK_BYTES:
            return DeviceStatus(True, f"Espace disque faible : {human_size(usage.free)} libres", warning=True)
        return DeviceStatus(True, f"{human_size(usage.free)} libres")
