#!/usr/bin/env bash
set -e

# --- wait for Postgres ---
python - <<'PY'
import os, time, psycopg
dsn = (
    f"host={os.environ['POSTGRES_HOST']} "
    f"port={os.environ['POSTGRES_PORT']} "
    f"dbname={os.environ['POSTGRES_DB']} "
    f"user={os.environ['POSTGRES_USER']} "
    f"password={os.environ['POSTGRES_PASSWORD']}"
)
for _ in range(60):
    try:
        with psycopg.connect(dsn) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
            break
    except Exception:
        time.sleep(1)
else:
    raise SystemExit("Postgres not reachable")
PY

# --- wait for Redis ---
python - <<'PY'
import os, time, redis, urllib.parse
url = os.environ.get("REDIS_URL","redis://redis:6379/0")
r = redis.Redis.from_url(url)
for _ in range(60):
    try:
        r.ping()
        break
    except Exception:
        time.sleep(1)
else:
    raise SystemExit("Redis not reachable")
PY

# Create Django project if missing
if [ ! -f "app/manage.py" ]; then
  echo "Creating Django project..."
  django-admin startproject core app
fi

cd app

# Patch settings.py for Postgres, Allowed Hosts, Static/Media, Celery
SETTINGS="core/settings.py"
python - <<'PY'
from pathlib import Path
import os, re
p = Path("core/settings.py")
s = p.read_text()

if "import os" not in s:
    s = s.replace("from pathlib import Path", "from pathlib import Path\nimport os")

# Allowed hosts
s = re.sub(r"ALLOWED_HOSTS\s*=.*", "ALLOWED_HOSTS = os.environ.get('DJANGO_ALLOWED_HOSTS','*').split(',')", s)

# Database
if "django.db.backends.postgresql" not in s:
    s = s.replace(
        "ENGINE': 'django.db.backends.sqlite3'",
        "ENGINE': 'django.db.backends.postgresql'"
    ).replace(
        "NAME': BASE_DIR / 'db.sqlite3'",
        "NAME': os.environ['POSTGRES_DB']"
    )
    s += """

DATABASES['default'].update({
    'USER': os.environ['POSTGRES_USER'],
    'PASSWORD': os.environ['POSTGRES_PASSWORD'],
    'HOST': os.environ.get('POSTGRES_HOST','db'),
    'PORT': os.environ.get('POSTGRES_PORT','5432'),
})
"""

# Static/Media
if "STATIC_ROOT" not in s:
    s += """
STATIC_URL = '/static/'
STATIC_ROOT = os.path.join(BASE_DIR, 'static')
MEDIA_URL = '/media/'
MEDIA_ROOT = os.path.join(BASE_DIR, 'media')
"""

# Time zone
if "TIME_ZONE" in s:
    s = re.sub(r"TIME_ZONE\s*=.*", "TIME_ZONE = os.environ.get('TIME_ZONE','UTC')", s)
else:
    s += "\nTIME_ZONE = os.environ.get('TIME_ZONE','UTC')\n"
if "USE_TZ" not in s:
    s += "USE_TZ = True\n"

# Celery config
if "CELERY_BROKER_URL" not in s:
    s += """
# Celery (Redis)
CELERY_BROKER_URL = os.environ.get('CELERY_BROKER_URL', 'redis://redis:6379/0')
CELERY_RESULT_BACKEND = os.environ.get('CELERY_RESULT_BACKEND', 'redis://redis:6379/1')
CELERY_TASK_ALWAYS_EAGER = False
CELERY_TIMEZONE = TIME_ZONE
"""

p.write_text(s)
PY

# Ensure demo app exists with a task and a simple trigger view
if [ ! -d "demo" ]; then
  python - <<'PY'
from pathlib import Path
Path("demo").mkdir(parents=True, exist_ok=True)
Path("demo/__init__.py").write_text("")
Path("demo/apps.py").write_text("from django.apps import AppConfig\n\nclass DemoConfig(AppConfig):\n    default_auto_field = 'django.db.models.BigAutoField'\n    name = 'demo'\n")
Path("demo/tasks.py").write_text(
    "from celery import shared_task\nimport time\n\n@shared_task\ndef add(x, y):\n    time.sleep(2)\n    return x + y\n"
)
Path("demo/views.py").write_text(
    "from django.http import JsonResponse\nfrom .tasks import add\n\ndef ping(request):\n    r = add.delay(2, 3)\n    return JsonResponse({'task_id': r.id, 'status': 'queued'})\n"
)
Path("demo/urls.py").write_text(
    "from django.urls import path\nfrom .views import ping\n\nurlpatterns = [ path('ping/', ping, name='ping') ]\n"
)
PY

  # add app to INSTALLED_APPS & wire urls
  python - <<'PY'
from pathlib import Path
sp = Path("core/settings.py")
s = sp.read_text()
if "demo" not in s:
    s = s.replace("INSTALLED_APPS = [", "INSTALLED_APPS = [\n    'demo',")
sp.write_text(s)

up = Path("core/urls.py")
u = up.read_text()
if "include" not in u:
    u = u.replace("from django.urls import path", "from django.urls import path, include")
if "demo/" not in u:
    u = u.replace("urlpatterns = [", "urlpatterns = [\n    path('demo/', include('demo.urls')),")
up.write_text(u)
PY
fi

# Make a celery.py in core
if [ ! -f "core/celery.py" ]; then
  cat > core/celery.py <<'PY'
import os
from celery import Celery

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'core.settings')

app = Celery('core')
app.config_from_object('django.conf:settings', namespace='CELERY')
app.autodiscover_tasks()
PY
  # ensure __init__ imports celery app
  python - <<'PY'
from pathlib import Path
p = Path("core/__init__.py")
text = p.read_text() if p.exists() else ""
if "from .celery import app as celery_app" not in text:
    text += "\nfrom .celery import app as celery_app\n__all__ = ('celery_app',)\n"
p.write_text(text)
PY
fi

# Migrate first (without silent failure)
echo "Running database migrations..."
python manage.py migrate --noinput

# Then create superuser with proper error handling
echo "Creating superuser if needed..."
python - <<'PY'
import os, django, time
os.environ.setdefault("DJANGO_SETTINGS_MODULE","core.settings")

# Small delay to ensure migrations are fully complete
time.sleep(2)

try:
    django.setup()
    from django.contrib.auth import get_user_model
    User = get_user_model()
    u = os.environ.get("DJANGO_SUPERUSER_USERNAME","admin")
    if not User.objects.filter(username=u).exists():
        print(f"Creating superuser: {u}")
        User.objects.create_superuser(
            username=os.environ.get("DJANGO_SUPERUSER_USERNAME","admin"),
            email=os.environ.get("DJANGO_SUPERUSER_EMAIL","admin@example.com"),
            password=os.environ.get("DJANGO_SUPERUSER_PASSWORD","admin123"),
        )
        print("Superuser created successfully!")
    else:
        print(f"Superuser {u} already exists")
except Exception as e:
    print(f"Warning: Could not create superuser: {e}")
    print("You can create it manually later with: docker-compose exec web python manage.py createsuperuser")
PY

python manage.py collectstatic --noinput || true

# Hand over to the container's final CMD
exec "$@"
