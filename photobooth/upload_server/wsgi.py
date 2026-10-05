"""Point d'entrée WSGI pour un serveur de production : gunicorn -w 2 -b 127.0.0.1:8000 wsgi:app"""

from app import create_app

app = create_app()
