"""Journalisation : console + logs/photobooth.log avec rotation automatique."""

from __future__ import annotations

import logging
import sys
import threading
from logging.handlers import RotatingFileHandler
from pathlib import Path

LOG_FILE_NAME = "photobooth.log"
LOG_FORMAT = "%(asctime)s [%(levelname)s] %(name)s : %(message)s"
_HANDLER_MARK = "_photobooth_handler"


def setup_logging(log_dir: Path, level: str = "INFO") -> Path:
    """Configure les journaux (2 Mo par fichier, 10 fichiers conservés) et renvoie le chemin du fichier."""
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / LOG_FILE_NAME
    formatter = logging.Formatter(LOG_FORMAT, "%Y-%m-%d %H:%M:%S")

    root = logging.getLogger()
    for handler in list(root.handlers):
        if getattr(handler, _HANDLER_MARK, False):
            root.removeHandler(handler)
            handler.close()

    file_handler = RotatingFileHandler(log_file, maxBytes=2_000_000, backupCount=10, encoding="utf-8", delay=True)
    console_handler = logging.StreamHandler(sys.stderr)
    for handler in (file_handler, console_handler):
        handler.setFormatter(formatter)
        setattr(handler, _HANDLER_MARK, True)
        root.addHandler(handler)
    root.setLevel(getattr(logging, level.upper(), logging.INFO))

    for noisy in ("waitress", "werkzeug", "urllib3", "PIL"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    _install_exception_hooks()
    return log_file


def _install_exception_hooks() -> None:
    """Toute exception non gérée est journalisée au lieu de disparaître silencieusement."""
    logger = logging.getLogger("photobooth")

    def log_exception(exc_type, exc_value, exc_traceback) -> None:  # type: ignore[no-untyped-def]
        if issubclass(exc_type, KeyboardInterrupt):
            sys.__excepthook__(exc_type, exc_value, exc_traceback)
            return
        logger.critical("Exception non gérée", exc_info=(exc_type, exc_value, exc_traceback))

    def log_thread_exception(args: threading.ExceptHookArgs) -> None:
        if args.exc_type is SystemExit or args.exc_value is None:
            return
        thread_name = args.thread.name if args.thread else "?"
        logger.error(
            "Exception non gérée dans le thread %s",
            thread_name,
            exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
        )

    sys.excepthook = log_exception
    threading.excepthook = log_thread_exception
