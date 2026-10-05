"""Exceptions métier : chacune porte un message affichable et un code HTTP."""

from __future__ import annotations


class PhotoboothError(Exception):
    """Erreur prévue, dont le message peut être montré tel quel à l'utilisateur."""

    status_code = 500
    error_code = "error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class ValidationError(PhotoboothError):
    """Donnée saisie invalide."""

    status_code = 400
    error_code = "invalid"


class NotFoundError(PhotoboothError):
    """Ressource introuvable (photo, cadre, événement…)."""

    status_code = 404
    error_code = "not_found"


class ConflictError(PhotoboothError):
    """Action impossible dans l'état actuel (capture déjà en cours, limite atteinte…)."""

    status_code = 409
    error_code = "conflict"


class TooManyAttemptsError(PhotoboothError):
    """Trop d'essais de code PIN : saisie bloquée quelques instants."""

    status_code = 429
    error_code = "too_many_attempts"


class CameraError(PhotoboothError):
    """Problème matériel ou logiciel de l'appareil photo."""

    status_code = 503
    error_code = "camera_error"


class PrinterError(PhotoboothError):
    """Problème d'impression (imprimante absente, hors ligne, erreur du pilote…)."""

    status_code = 503
    error_code = "printer_error"


class StorageError(PhotoboothError):
    """Écriture impossible sur le disque (disque plein, droits…)."""

    status_code = 507
    error_code = "storage_error"


class UploadError(PhotoboothError):
    """Échec de l'envoi d'une photo vers le serveur web."""

    status_code = 502
    error_code = "upload_error"
