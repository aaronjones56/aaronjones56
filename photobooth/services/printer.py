"""Imprimantes : interface commune, simulation et impression Windows (pywin32).

La Canon SELPHY CP1500 s'installe comme une imprimante Windows classique : il suffit
de la choisir dans l'administration. L'image est centrée et mise à l'échelle sur la
page (10 x 15 cm) en mode « fill » (bord à bord) ou « fit » (image entière).
"""

from __future__ import annotations

import logging
import threading
import time
from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

from PIL import Image, ImageOps

from services.devices import DeviceStatus
from services.errors import PrinterError

if TYPE_CHECKING:
    from config import Config

logger = logging.getLogger(__name__)

# Constantes de WinSpool.h
PRINTER_ATTRIBUTE_WORK_OFFLINE = 0x00000400
_BLOCKING_STATUSES: tuple[tuple[int, str], ...] = (
    (0x00000080, "hors ligne"),
    (0x00000002, "en erreur"),
    (0x00000008, "bourrage papier"),
    (0x00000010, "plus de papier"),
    (0x00000040, "problème de papier"),
    (0x00040000, "plus d'encre"),
    (0x00400000, "capot ouvert"),
    (0x00100000, "intervention nécessaire"),
    (0x00001000, "indisponible"),
    (0x00000001, "en pause"),
    (0x00000004, "suppression en cours"),
    (0x00200000, "mémoire saturée"),
)
_WARNING_STATUSES: tuple[tuple[int, str], ...] = (
    (0x00020000, "encre faible"),
    (0x00000800, "bac de sortie plein"),
)
# Index GetDeviceCaps (wingdi.h)
HORZRES, VERTRES = 8, 10
PHYSICALWIDTH, PHYSICALHEIGHT, PHYSICALOFFSETX, PHYSICALOFFSETY = 110, 111, 112, 113


@dataclass(frozen=True)
class PrinterInfo:
    name: str
    is_default: bool = False

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class PrinterProvider(ABC):
    """Interface commune à toutes les imprimantes."""

    mode = "abstract"
    label = "Imprimante"

    def __init__(self, printer_name: str = "") -> None:
        self._printer_name = printer_name.strip()

    @property
    def printer_name(self) -> str:
        """Imprimante sélectionnée (vide = imprimante par défaut du système)."""
        return self._printer_name

    def set_printer(self, name: str) -> None:
        self._printer_name = name.strip()

    def list_printers(self) -> list[PrinterInfo]:
        return []

    @abstractmethod
    def check(self) -> DeviceStatus:
        """Vérifie que l'imprimante est prête."""

    @abstractmethod
    def print_image(self, image_path: Path, copies: int = 1, job_name: str = "Photobooth") -> None:
        """Imprime ``image_path`` ; lève PrinterError en cas de problème."""

    def describe(self) -> dict[str, Any]:
        return {"mode": self.mode, "label": self.label, "name": self.printer_name}


class NullPrinter(PrinterProvider):
    """Simulation pour le développement : rien n'est imprimé, tout est journalisé."""

    mode = "null"
    label = "Simulation (aucune impression réelle)"
    SIMULATED_NAME = "Imprimante simulée"

    def __init__(self, printer_name: str = "", simulated_delay: float = 1.5) -> None:
        super().__init__(printer_name or self.SIMULATED_NAME)
        self.simulated_delay = simulated_delay
        self.jobs: list[tuple[Path, int]] = []

    def list_printers(self) -> list[PrinterInfo]:
        return [PrinterInfo(self.SIMULATED_NAME, True)]

    def check(self) -> DeviceStatus:
        return DeviceStatus(True, "Mode simulation : aucune impression réelle")

    def print_image(self, image_path: Path, copies: int = 1, job_name: str = "Photobooth") -> None:
        if not image_path.is_file():
            raise PrinterError("Le fichier à imprimer est introuvable.")
        logger.info("[Simulation] Impression de %s (%d copie(s))", image_path.name, copies)
        if self.simulated_delay:
            time.sleep(self.simulated_delay)
        self.jobs = [*self.jobs[-49:], (image_path, copies)]


class WindowsPrinter(PrinterProvider):
    """Impression Windows via GDI (pywin32) : fonctionne avec toute imprimante installée."""

    mode = "windows"
    label = "Imprimante Windows"

    def __init__(self, printer_name: str = "", fit_mode: str = "fill") -> None:
        super().__init__(printer_name)
        self.fit_mode = fit_mode
        self._lock = threading.Lock()

    @staticmethod
    def _win32() -> tuple[Any, Any]:
        try:
            import win32print
            import win32ui
        except ImportError as exc:
            raise PrinterError("pywin32 n'est pas installé : l'impression Windows est indisponible.") from exc
        return win32print, win32ui

    def resolved_name(self) -> str:
        """Imprimante choisie, ou à défaut l'imprimante par défaut de Windows."""
        if self.printer_name:
            return self.printer_name
        win32print, _ = self._win32()
        try:
            return win32print.GetDefaultPrinter()
        except Exception as exc:  # noqa: BLE001 - pywintypes.error
            raise PrinterError("Aucune imprimante sélectionnée et pas d'imprimante par défaut.") from exc

    def list_printers(self) -> list[PrinterInfo]:
        try:
            win32print, _ = self._win32()
        except PrinterError:
            return []
        flags = win32print.PRINTER_ENUM_LOCAL | win32print.PRINTER_ENUM_CONNECTIONS
        try:
            names = sorted({entry["pPrinterName"] for entry in win32print.EnumPrinters(flags, None, 4)})
        except Exception:  # noqa: BLE001
            logger.exception("Impossible de lister les imprimantes Windows")
            return []
        try:
            default = win32print.GetDefaultPrinter()
        except Exception:  # noqa: BLE001
            default = ""
        return [PrinterInfo(name, name == default) for name in names]

    def _problems(self, name: str) -> tuple[list[str], list[str], int]:
        """Problèmes bloquants, avertissements et nombre de travaux en attente."""
        win32print, _ = self._win32()
        try:
            handle = win32print.OpenPrinter(name)
        except Exception as exc:  # noqa: BLE001
            raise PrinterError(f"Imprimante introuvable : {name}") from exc
        try:
            info = win32print.GetPrinter(handle, 2)
        finally:
            win32print.ClosePrinter(handle)
        status = int(info.get("Status") or 0)
        attributes = int(info.get("Attributes") or 0)
        blocking = [label for flag, label in _BLOCKING_STATUSES if status & flag]
        if attributes & PRINTER_ATTRIBUTE_WORK_OFFLINE and "hors ligne" not in blocking:
            blocking.insert(0, "hors ligne")
        warnings = [label for flag, label in _WARNING_STATUSES if status & flag]
        return blocking, warnings, int(info.get("cJobs") or 0)

    def check(self) -> DeviceStatus:
        try:
            name = self.resolved_name()
            blocking, warnings, jobs = self._problems(name)
        except PrinterError as exc:
            return DeviceStatus(False, exc.message)
        if blocking:
            return DeviceStatus(False, f"{name} : {', '.join(blocking)}")
        details = [*warnings, f"{jobs} impression(s) en attente"] if jobs else warnings
        message = f"{name} prête" + (f" ({', '.join(details)})" if details else "")
        return DeviceStatus(True, message, warning=bool(warnings) or jobs > 3)

    def print_image(self, image_path: Path, copies: int = 1, job_name: str = "Photobooth") -> None:
        if not image_path.is_file():
            raise PrinterError("Le fichier à imprimer est introuvable.")
        name = self.resolved_name()
        blocking, _warnings, _jobs = self._problems(name)
        if blocking:
            raise PrinterError(f"L'imprimante est {', '.join(blocking)}.")
        with self._lock:
            try:
                self._print_gdi(name, image_path, max(1, copies), job_name)
            except PrinterError:
                raise
            except Exception as exc:  # noqa: BLE001 - erreurs pywin32 variées
                logger.exception("Erreur du pilote d'impression (%s)", name)
                raise PrinterError("Erreur d'impression : vérifiez l'imprimante.") from exc
        logger.info("Impression envoyée à %s : %s (%d copie(s))", name, image_path.name, copies)

    def _print_gdi(self, name: str, image_path: Path, copies: int, job_name: str) -> None:
        from PIL import ImageWin

        _, win32ui = self._win32()
        with Image.open(image_path) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
        device = win32ui.CreateDC()
        device.CreatePrinterDC(name)
        try:
            printable = (device.GetDeviceCaps(HORZRES), device.GetDeviceCaps(VERTRES))
            page = (device.GetDeviceCaps(PHYSICALWIDTH), device.GetDeviceCaps(PHYSICALHEIGHT))
            offset = (device.GetDeviceCaps(PHYSICALOFFSETX), device.GetDeviceCaps(PHYSICALOFFSETY))
            if (image.width > image.height) != (page[0] > page[1]):
                image = image.rotate(90, expand=True)
            box = compute_print_box(image.size, page, printable, offset, self.fit_mode)
            dib = ImageWin.Dib(image)
            device.StartDoc(job_name)
            for _ in range(copies):
                device.StartPage()
                dib.draw(device.GetHandleOutput(), box)
                device.EndPage()
            device.EndDoc()
        finally:
            device.DeleteDC()


def compute_print_box(
    image_size: tuple[int, int],
    page_size: tuple[int, int],
    printable_size: tuple[int, int],
    offset: tuple[int, int],
    mode: str = "fill",
) -> tuple[int, int, int, int]:
    """Rectangle d'impression (coordonnées de la zone imprimable), image centrée sans déformation.

    ``fill`` couvre toute la feuille (bord à bord, léger rognage possible) ;
    ``fit`` affiche l'image entière dans la zone imprimable (marges blanches possibles).
    """
    image_w, image_h = image_size
    if mode == "fit":
        area_w, area_h = printable_size
        scale = min(area_w / image_w, area_h / image_h)
        width, height = round(image_w * scale), round(image_h * scale)
        left, top = (area_w - width) // 2, (area_h - height) // 2
    else:
        page_w, page_h = page_size
        scale = max(page_w / image_w, page_h / image_h)
        width, height = round(image_w * scale), round(image_h * scale)
        left, top = (page_w - width) // 2 - offset[0], (page_h - height) // 2 - offset[1]
    return left, top, left + width, top + height


PrinterFactory = Callable[["Config", str], PrinterProvider]
_REGISTRY: dict[str, PrinterFactory] = {
    "null": lambda config, name: NullPrinter(name, config.printer_simulated_delay),
    "windows": lambda config, name: WindowsPrinter(name, config.print_fit_mode),
}


def register_printer(mode: str, factory: PrinterFactory) -> None:
    _REGISTRY[mode.lower()] = factory


def create_printer(config: Config, printer_name: str) -> PrinterProvider:
    factory = _REGISTRY.get(config.printer_mode, _REGISTRY["null"])
    return factory(config, printer_name)
