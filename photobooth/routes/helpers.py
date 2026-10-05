"""Outils communs aux routes : services, réponses JSON, code PIN."""

from __future__ import annotations

import hmac
from collections.abc import Callable
from functools import wraps
from typing import Any

from flask import Response, current_app, jsonify, redirect, request, session, url_for

from services.codes import normalize_code
from services.container import Services
from services.devices import DeviceStatus
from services.errors import NotFoundError, TooManyAttemptsError, ValidationError
from services.system_service import LoginThrottle


def get_services() -> Services:
    return current_app.extensions["photobooth"]


def json_ok(**payload: Any) -> Response:
    return jsonify({"ok": True, **payload})


def json_error(message: str, status: int = 400, code: str = "error") -> Response:
    response = jsonify({"ok": False, "error": message, "code": code})
    response.status_code = status
    return response


def read_json() -> dict[str, Any]:
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def require_photo_code(raw: str) -> str:
    code = normalize_code(raw)
    if code is None:
        raise NotFoundError("Photo introuvable.")
    return code


def safe_check(check: Callable[[], DeviceStatus]) -> dict[str, Any]:
    """Exécute une vérification matérielle sans jamais lever d'exception."""
    try:
        return check().to_dict()
    except Exception as exc:  # noqa: BLE001 - un pilote défaillant ne doit pas casser la page
        current_app.logger.exception("Vérification matérielle en échec")
        return DeviceStatus(False, f"Vérification impossible : {exc}").to_dict()


def check_pin(pin: Any) -> None:
    """Vérifie le code PIN administrateur (comparaison à temps constant, essais limités)."""
    throttle: LoginThrottle = current_app.extensions["login_throttle"]
    locked = throttle.seconds_locked()
    if locked:
        raise TooManyAttemptsError(f"Trop d'essais : réessayez dans {locked} secondes.")
    expected = get_services().config.admin_pin.encode("utf-8")
    if not hmac.compare_digest(str(pin or "").encode("utf-8"), expected):
        throttle.failure()
        current_app.logger.warning("Code PIN administrateur incorrect")
        raise ValidationError("Code PIN incorrect.")
    throttle.success()


def login_admin() -> None:
    session.clear()
    session["admin"] = True
    session.permanent = True


def is_admin() -> bool:
    return bool(session.get("admin"))


def admin_required(view: Callable[..., Any]) -> Callable[..., Any]:
    """Réservé à l'administrateur connecté ; JSON 401 pour l'API, redirection sinon."""

    @wraps(view)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        if not is_admin():
            if request.path.startswith("/api/"):
                return json_error("Connexion administrateur requise.", 401, "auth_required")
            return redirect(url_for("admin.admin_page"))
        return view(*args, **kwargs)

    return wrapper
