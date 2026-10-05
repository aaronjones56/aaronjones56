"""Services métier du photobooth (matériel, stockage, montage, upload…).

Chaque module est indépendant de Flask : les routes HTTP (dossier ``routes``)
et la ligne de commande (``manage.py``) utilisent les mêmes services, assemblés
par ``services.container.build_services``.
"""
