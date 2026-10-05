"""Appareils photo : interface commune et trois modes prêts à l'emploi.

* ``mock``     : simulation avec une photo de test (aucun matériel requis) ;
* ``webcam``   : webcam USB via OpenCV ;
* ``external`` : commande Windows configurable qui déclenche un vrai appareil
  (digiCamControl, gPhoto2, logiciel constructeur…).

Pour ajouter un modèle (CanonCamera, NikonCamera, SonyCamera…) : créer une sous-classe
de ``CameraProvider`` puis l'enregistrer avec ``register_camera("canon", fabrique)``.
"""

from __future__ import annotations

import io
import logging
import math
import os
import shlex
import shutil
import subprocess
import threading
import time
from abc import ABC, abstractmethod
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

import requests
from PIL import Image, ImageDraw, ImageOps, UnidentifiedImageError

from services.devices import DeviceStatus, is_readable_image
from services.errors import CameraError
from services.fonts import draw_text, load_font
from services.utils import atomic_write_bytes

if TYPE_CHECKING:
    from config import Config

logger = logging.getLogger(__name__)

PREVIEW_MAX_WIDTH = 960
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


class CameraProvider(ABC):
    """Interface commune à tous les appareils photo."""

    mode = "abstract"
    label = "Appareil photo"

    @abstractmethod
    def capture(self, output_path: Path) -> Path:
        """Prend une photo et l'enregistre (JPEG) dans ``output_path``. Lève CameraError en cas d'échec."""

    @abstractmethod
    def check(self) -> DeviceStatus:
        """Vérifie que l'appareil est prêt."""

    @property
    def supports_preview(self) -> bool:
        """Vrai si l'appareil fournit un aperçu en direct."""
        return False

    def preview_jpeg(self) -> bytes | None:
        """Image d'aperçu (JPEG) ; None si l'appareil n'en fournit pas."""
        return None

    def close(self) -> None:
        """Libère le matériel (appelé à l'arrêt de l'application)."""

    def describe(self) -> dict[str, Any]:
        return {"mode": self.mode, "label": self.label, "preview": self.supports_preview}


class MockCamera(CameraProvider):
    """Simulation : renvoie la photo de test, horodatée pour distinguer chaque prise."""

    mode = "mock"
    label = "Simulation (photo de test)"

    def __init__(self, test_photo: Path) -> None:
        self.test_photo = test_photo
        self._preview_base: Image.Image | None = None
        self._lock = threading.Lock()

    def _load_source(self) -> Image.Image:
        if not self.test_photo.is_file():
            from services.assets import generate_test_photo

            logger.info("Photo de test absente : génération de %s", self.test_photo)
            generate_test_photo(self.test_photo)
        try:
            with Image.open(self.test_photo) as image:
                return ImageOps.exif_transpose(image).convert("RGB")
        except (OSError, UnidentifiedImageError) as exc:
            raise CameraError(f"Photo de test illisible : {self.test_photo.name}") from exc

    def capture(self, output_path: Path) -> Path:
        image = self._load_source()
        draw = ImageDraw.Draw(image)
        font = load_font(max(18, image.width // 60), bold=True)
        stamp = f"TEST  {datetime.now():%d/%m/%Y %H:%M:%S}"
        draw_text(draw, (image.width * 0.03, image.height * 0.03), stamp, font, (255, 255, 255))
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=95)
        atomic_write_bytes(output_path, buffer.getvalue())
        return output_path

    @property
    def supports_preview(self) -> bool:
        return True

    def preview_jpeg(self) -> bytes:
        with self._lock:
            if self._preview_base is None:
                base = self._load_source()
                base.thumbnail((PREVIEW_MAX_WIDTH, PREVIEW_MAX_WIDTH), Image.Resampling.LANCZOS)
                self._preview_base = base
            base = self._preview_base
        # Léger panoramique et voyant clignotant : l'aperçu « vit » comme une vraie caméra.
        drift = max(4, base.width // 60)
        phase = time.time() * 0.8
        dx = round(drift + drift * math.sin(phase))
        dy = round(drift / 2 + drift / 2 * math.cos(phase * 0.7))
        frame = base.crop((dx, dy, base.width - 2 * drift + dx, base.height - drift + dy))
        if int(time.time() * 2) % 2 == 0:
            draw = ImageDraw.Draw(frame)
            radius, center_x, center_y = max(6, frame.width // 90), frame.width / 2, frame.height * 0.04
            draw.ellipse(
                (center_x - radius, center_y - radius, center_x + radius, center_y + radius), fill=(255, 59, 92)
            )
        buffer = io.BytesIO()
        frame.save(buffer, format="JPEG", quality=78)
        return buffer.getvalue()

    def check(self) -> DeviceStatus:
        if self.test_photo.is_file():
            return DeviceStatus(True, f"Simulation avec {self.test_photo.name}")
        return DeviceStatus(True, "Simulation (photo de test générée au premier déclenchement)")


class WebcamCamera(CameraProvider):
    """Webcam USB lue en continu par un thread ; libérée après 2 minutes sans utilisation."""

    mode = "webcam"
    label = "Webcam (OpenCV)"
    FIRST_FRAME_TIMEOUT = 6.0
    IDLE_RELEASE_SECONDS = 120.0
    MAX_READ_FAILURES = 50

    def __init__(self, device: int = 0, width: int = 1920, height: int = 1080, backend: str = "auto") -> None:
        self.device = device
        self.width = width
        self.height = height
        self.backend = backend
        self._frame: Any = None
        self._frame_time = 0.0
        self._last_access = 0.0
        self._error: str | None = None
        self._frame_lock = threading.Lock()
        self._start_lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    @staticmethod
    def _cv2() -> Any:
        try:
            import cv2
        except ImportError as exc:
            raise CameraError("OpenCV n'est pas installé (pip install opencv-python-headless).") from exc
        return cv2

    def _backend_flag(self, cv2: Any) -> int:
        backend = self.backend
        if backend == "auto":
            backend = "dshow" if os.name == "nt" else "any"
        flags = {"dshow": cv2.CAP_DSHOW, "msmf": cv2.CAP_MSMF, "v4l2": cv2.CAP_V4L2, "any": cv2.CAP_ANY}
        return flags.get(backend, cv2.CAP_ANY)

    def _open(self) -> Any:
        cv2 = self._cv2()
        capture = cv2.VideoCapture(self.device, self._backend_flag(cv2))
        if not capture.isOpened():
            capture.release()
            raise CameraError(f"Webcam introuvable (CAMERA_DEVICE={self.device}). Est-elle branchée ?")
        capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        capture.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
        capture.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
        capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        return capture

    def _ensure_running(self) -> None:
        self._last_access = time.monotonic()
        with self._start_lock:
            if self._thread is not None and self._thread.is_alive():
                return
            capture = self._open()
            self._stop.clear()
            self._error = None
            with self._frame_lock:
                self._frame = None
            self._thread = threading.Thread(target=self._reader, args=(capture,), name="webcam", daemon=True)
            self._thread.start()
            logger.info("Webcam %s ouverte", self.device)

    def _reader(self, capture: Any) -> None:
        failures = 0
        try:
            while not self._stop.is_set():
                ok, frame = capture.read()
                if not ok or frame is None:
                    failures += 1
                    if failures >= self.MAX_READ_FAILURES:
                        self._error = "La webcam ne renvoie plus d'image (débranchée ?)."
                        logger.error(self._error)
                        break
                    time.sleep(0.05)
                    continue
                failures = 0
                with self._frame_lock:
                    self._frame = frame
                    self._frame_time = time.monotonic()
                if time.monotonic() - self._last_access > self.IDLE_RELEASE_SECONDS:
                    logger.info("Webcam inutilisée depuis %d s : libération", self.IDLE_RELEASE_SECONDS)
                    break
        except Exception:  # noqa: BLE001 - une erreur matérielle ne doit jamais arrêter l'application
            logger.exception("Erreur inattendue de la webcam")
            self._error = "Erreur inattendue de la webcam."
        finally:
            capture.release()
            with self._frame_lock:
                self._frame = None

    def _latest_frame(self, newer_than: float = 0.0, timeout: float = FIRST_FRAME_TIMEOUT) -> Any:
        self._ensure_running()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._frame_lock:
                frame, stamp = self._frame, self._frame_time
            if frame is not None and stamp > newer_than:
                return frame
            thread = self._thread
            if thread is None or not thread.is_alive():
                raise CameraError(self._error or "La webcam s'est arrêtée.")
            time.sleep(0.02)
        raise CameraError("La webcam ne répond pas (aucune image reçue).")

    @property
    def supports_preview(self) -> bool:
        return True

    def preview_jpeg(self) -> bytes:
        cv2 = self._cv2()
        frame = self._latest_frame()
        height, width = frame.shape[:2]
        if width > PREVIEW_MAX_WIDTH:
            new_size = (PREVIEW_MAX_WIDTH, round(height * PREVIEW_MAX_WIDTH / width))
            frame = cv2.resize(frame, new_size, interpolation=cv2.INTER_AREA)
        ok, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75])
        if not ok:
            raise CameraError("Encodage de l'aperçu impossible.")
        return buffer.tobytes()

    def capture(self, output_path: Path) -> Path:
        cv2 = self._cv2()
        frame = self._latest_frame(newer_than=time.monotonic(), timeout=3.0)
        ok, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        if not ok:
            raise CameraError("Encodage de la photo impossible.")
        atomic_write_bytes(output_path, buffer.tobytes())
        return output_path

    def check(self) -> DeviceStatus:
        try:
            frame = self._latest_frame()
        except CameraError as exc:
            return DeviceStatus(False, exc.message)
        height, width = frame.shape[:2]
        return DeviceStatus(True, f"Webcam {self.device} : {width}x{height}")

    def close(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None:
            thread.join(timeout=3)
        self._thread = None


class ExternalCommandCamera(CameraProvider):
    """Déclenche un appareil photo via une commande externe.

    Variables remplacées dans CAMERA_CAPTURE_COMMAND : ``{output}`` (chemin complet du
    JPEG attendu), ``{output_dir}``, ``{filename}`` et ``{stem}``. Si le logiciel ne
    sait pas choisir le nom du fichier, CAMERA_WATCH_DIR indique le dossier où il
    dépose les photos : la plus récente est alors récupérée.
    """

    mode = "external"
    label = "Appareil photo (commande externe)"

    def __init__(self, command: str, timeout: int = 30, watch_dir: Path | None = None, preview_url: str = "") -> None:
        self.command = command.strip()
        self.timeout = timeout
        self.watch_dir = watch_dir
        self.preview_url = preview_url.strip()

    def capture(self, output_path: Path) -> Path:
        if not self.command:
            raise CameraError("CAMERA_CAPTURE_COMMAND n'est pas configurée dans le fichier .env.")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.unlink(missing_ok=True)
        command = render_command(self.command, output_path)
        started = time.time()
        logger.info("Déclenchement de l'appareil photo : %s", command)
        try:
            result = subprocess.run(
                command,
                shell=True,
                check=False,
                capture_output=True,
                text=True,
                errors="replace",
                timeout=self.timeout,
                creationflags=_NO_WINDOW,
            )
        except subprocess.TimeoutExpired as exc:
            raise CameraError(f"L'appareil photo n'a pas répondu en {self.timeout} secondes.") from exc
        except OSError as exc:
            raise CameraError(f"Impossible de lancer la commande de capture : {exc}") from exc
        if result.returncode != 0:
            details = (result.stderr or result.stdout or "").strip()[-500:]
            logger.error("Commande de capture en échec (code %s) : %s", result.returncode, details)
            raise CameraError(f"La commande de capture a échoué (code {result.returncode}).")

        remaining = max(2.0, self.timeout - (time.time() - started))
        if self.watch_dir is not None:
            source = wait_for_new_image(self.watch_dir, since=started, timeout=remaining)
            shutil.move(str(source), str(output_path))
        else:
            wait_for_stable_file(output_path, timeout=remaining)
        if not is_readable_image(output_path):
            raise CameraError("La photo reçue de l'appareil est illisible (JPEG attendu).")
        return output_path

    @property
    def supports_preview(self) -> bool:
        return bool(self.preview_url)

    def preview_jpeg(self) -> bytes | None:
        if not self.preview_url:
            return None
        try:
            response = requests.get(self.preview_url, timeout=2)
        except requests.RequestException as exc:
            raise CameraError("Aperçu de l'appareil photo indisponible.") from exc
        if response.status_code != 200 or not response.content:
            raise CameraError("Aperçu de l'appareil photo indisponible.")
        return response.content

    def check(self) -> DeviceStatus:
        if not self.command:
            return DeviceStatus(False, "CAMERA_CAPTURE_COMMAND n'est pas configurée")
        executable = command_executable(self.command)
        if executable and not (Path(executable).exists() or shutil.which(executable)):
            return DeviceStatus(False, f"Programme introuvable : {executable}")
        if self.watch_dir is not None and not self.watch_dir.is_dir():
            return DeviceStatus(False, f"Dossier surveillé introuvable : {self.watch_dir}")
        message = "Commande de capture configurée"
        if self.preview_url:
            try:
                ok = requests.get(self.preview_url, timeout=2).status_code == 200
            except requests.RequestException:
                ok = False
            message += " ; aperçu disponible" if ok else " ; aperçu injoignable"
        return DeviceStatus(True, message)


def render_command(template: str, output_path: Path) -> str:
    """Remplace {output}, {output_dir}, {filename} et {stem} dans la commande."""
    replacements = {
        "{output}": str(output_path),
        "{output_dir}": str(output_path.parent),
        "{filename}": output_path.name,
        "{stem}": output_path.stem,
    }
    command = template
    for placeholder, value in replacements.items():
        command = command.replace(placeholder, value)
    return command


def command_executable(command: str) -> str:
    """Premier élément de la commande (le programme), sans guillemets."""
    try:
        parts = shlex.split(command, posix=False)
    except ValueError:
        return ""
    return parts[0].strip('"') if parts else ""


def wait_for_stable_file(path: Path, timeout: float, interval: float = 0.15) -> Path:
    """Attend que le fichier existe et que sa taille ne bouge plus (écriture terminée)."""
    deadline = time.monotonic() + timeout
    last_size = -1
    while time.monotonic() < deadline:
        size = path.stat().st_size if path.is_file() else -1
        if size > 0 and size == last_size:
            return path
        last_size = size
        time.sleep(interval)
    raise CameraError("Aucune photo n'a été reçue de l'appareil photo.")


def wait_for_new_image(directory: Path, since: float, timeout: float) -> Path:
    """Attend l'apparition d'une nouvelle image dans ``directory`` et la renvoie."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        candidates = [
            path
            for path in directory.iterdir()
            if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES and path.stat().st_mtime >= since - 1
        ]
        if candidates:
            newest = max(candidates, key=lambda path: path.stat().st_mtime)
            return wait_for_stable_file(newest, timeout=max(1.0, deadline - time.monotonic()))
        time.sleep(0.2)
    raise CameraError(f"Aucune nouvelle photo dans {directory}.")


CameraFactory = Callable[["Config"], CameraProvider]
_REGISTRY: dict[str, CameraFactory] = {}


def register_camera(mode: str, factory: CameraFactory) -> None:
    """Rend un nouveau mode disponible pour CAMERA_MODE."""
    _REGISTRY[mode.lower()] = factory


def available_camera_modes() -> list[str]:
    return sorted(_REGISTRY)


def create_camera(config: Config) -> CameraProvider:
    factory = _REGISTRY.get(config.camera_mode)
    if factory is None:
        logger.error(
            "CAMERA_MODE=%s inconnu (modes : %s) : utilisation de la simulation",
            config.camera_mode,
            ", ".join(available_camera_modes()),
        )
        factory = _REGISTRY["mock"]
    return factory(config)


register_camera("mock", lambda config: MockCamera(config.test_photo))
register_camera(
    "webcam",
    lambda config: WebcamCamera(config.camera_device, config.camera_width, config.camera_height, config.camera_backend),
)
register_camera(
    "external",
    lambda config: ExternalCommandCamera(
        config.camera_capture_command,
        config.camera_capture_timeout,
        config.camera_watch_dir,
        config.camera_preview_url,
    ),
)
