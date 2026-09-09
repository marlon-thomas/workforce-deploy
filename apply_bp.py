import os, sys
sys.path.insert(0, "/authentik")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
import django
django.setup()
from authentik.blueprints.v1.importer import Importer
with open("/blueprints/workforce-app.yaml") as f:
    imp = Importer.from_string(f.read())
print("APPLY:", imp.apply())
