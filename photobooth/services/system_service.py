"""Fonctions système : connexion Internet, redémarrage, fermeture du kiosk, journaux."""

from __future__ import annotations

import io
import logging
import os
import socket
import subprocess
import sys
import threading
import time
import zipfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

import requests

from services.upload_service import health_url

logger = logging.getLogger(__name__)

RESTART_EXIT_CODE = 3
KIOSK_PROFILE_MARKER = "PhotoboothKioskProfile"
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


class ConnectivityMonitor:
    """État Internet / serveur photos, vérifié en arrière-plan (jamais bloquant)."""

    TTL_SECONDS = 30.0
    PROBES = (("1.1.1.1", 443), ("8.8.8.8", 53), ("9.9.9.9", 443))

    def __init__(self, upload_api_url: str = "") -> None:
        self.upload_api_url = upload_api_url
        self._internet: bool | None = None
        self._server: bool | None = None
        self._checked_at = 0.0
        self._refreshing = False
        self._lock = threading.Lock()

    def snapshot(self) -> dict[str, Any]:
        """Dernier état connu ; None tant que la première vérification n'est pas terminée."""
        self._refresh_if_stale()
        with self._lock:
            return {"internet": self._internet, "server": self._server, "server_configured": bool(self.upload_api_url)}

    def _refresh_if_stale(self) -> None:
        with self._lock:
            if self._refreshing or time.monotonic() - self._checked_at < self.TTL_SECONDS:
                return
            self._refreshing = True
        threading.Thread(target=self._refresh, name="connectivity", daemon=True).start()

    def _refresh(self) -> None:
        internet = server = None
        try:
            server = self._probe_server() if self.upload_api_url else None
            internet = bool(server) or self._probe_internet()
        finally:
            with self._lock:
                self._internet, self._server = internet, server
                self._checked_at = time.monotonic()
                self._refreshing = False

    def _probe_internet(self) -> bool:
        for host, port in self.PROBES:
            try:
                with socket.create_connection((host, port), timeout=2):
                    return True
            except OSError:
                continue
        return False

    def _probe_server(self) -> bool:
        try:
            return requests.get(health_url(self.upload_api_url), timeout=4).status_code < 500
        except requests.RequestException:
            return False


def schedule_exit(code: int, before_exit: Callable[[], None] | None = None, delay: float = 0.8) -> None:
    """Quitte le processus après ``delay`` secondes (le temps d'envoyer la réponse HTTP).

    Lancé par scripts/run_server.bat, le code 3 provoque un redémarrage automatique.
    """

    def _exit() -> None:
        time.sleep(delay)
        try:
            if before_exit is not None:
                before_exit()
        except Exception:  # noqa: BLE001
            logger.exception("Erreur pendant l'arrêt")
        logger.info("Arrêt du processus (code %d)", code)
        logging.shutdown()
        os._exit(code)

    threading.Thread(target=_exit, name="exit", daemon=True).start()


def restart_process(supervised: bool, before_exit: Callable[[], None] | None = None) -> None:
    """Redémarre l'application.

    Lancée par run_server.bat (supervisée), elle quitte avec le code 3 et le script la
    relance. Lancée à la main (python app.py), elle démarre elle-même un nouveau processus.
    """
    if supervised:
        schedule_exit(RESTART_EXIT_CODE, before_exit)
        return

    def relaunch() -> None:
        if before_exit is not None:
            before_exit()
        subprocess.Popen([sys.executable, *sys.argv], cwd=os.getcwd())

    schedule_exit(0, relaunch)


def close_kiosk_browser() -> None:
    """Ferme la fenêtre du navigateur lancée par start_kiosk.bat (profil dédié)."""
    try:
        if os.name == "nt":
            script = (
                "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*"
                + KIOSK_PROFILE_MARKER
                + "*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
            )
            subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script],
                capture_output=True,
                check=False,
                timeout=20,
                creationflags=_NO_WINDOW,
            )
        else:
            subprocess.run(["pkill", "-f", KIOSK_PROFILE_MARKER], capture_output=True, check=False, timeout=10)
        logger.info("Navigateur kiosk fermé")
    except (OSError, subprocess.SubprocessError) as exc:
        logger.warning("Impossible de fermer le navigateur kiosk : %s", exc)


def logs_zip(log_dir: Path) -> io.BytesIO:
    """Archive ZIP de tous les journaux (fichier courant et anciens fichiers)."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(log_dir.glob("*.log*")):
            if path.is_file():
                archive.write(path, arcname=path.name)
    buffer.seek(0)
    return buffer


class LoginThrottle:
    """Bloque temporairement la saisie du PIN après plusieurs erreurs."""

    def __init__(self, max_failures: int = 5, window_seconds: float = 300, lockout_seconds: float = 60) -> None:
        self.max_failures = max_failures
        self.window_seconds = window_seconds
        self.lockout_seconds = lockout_seconds
        self._failures: list[float] = []
        self._locked_until = 0.0
        self._lock = threading.Lock()

    def seconds_locked(self) -> int:
        with self._lock:
            return max(0, int(self._locked_until - time.monotonic() + 0.999))

    def failure(self) -> None:
        now = time.monotonic()
        with self._lock:
            self._failures = [stamp for stamp in self._failures if now - stamp < self.window_seconds] + [now]
            if len(self._failures) >= self.max_failures:
                self._locked_until = now + self.lockout_seconds
                self._failures.clear()

    def success(self) -> None:
        with self._lock:
            self._failures.clear()
