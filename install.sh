#!/bin/bash
set -e

# Check if pyenv is installed
if ! command -v pyenv &> /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m pyenv is not installed. Please install it before proceeding."
    exit 1
fi

# Variables
project_domain=""
project_path=$(dirname "$(realpath "$0")")
project_name=""
environment=""

# Prompt for user input
read -e -p $'\e[38;5;117m[1/3]\e[0m Your domain without protocol \e[38;5;223m(e.g., example.com)\e[0m: ' project_domain
read -e -p $'\e[38;5;117m[2/3]\e[0m Project name: ' project_name

# Environment selection with validation
echo -e "\e[38;5;117m[3/3]\e[0m Select environment:"
echo $'\e[38;5;207m1\e[0m - Development'
echo $'\e[38;5;207m2\e[0m - Production'

while true; do
    read -e -p $'Choose from \e[38;5;207m[1/2]\e[0m: ' env_choice
    case "$env_choice" in
        1|"")
            environment="local"
            break
            ;;
        2)
            environment="production"
            break
            ;;
        *)
            echo -e "\e[91m[ERROR]\e[0m Invalid choice. Please enter \e[38;5;117m1\e[0m or \e[38;5;117m2\e[0m."
            ;;
    esac
done

# Install necessary packages
echo -e "\e[38;5;72m[INFO]\e[0m Installing necessary packages..."
set +e
sudo apt update && sudo apt upgrade -y
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update or upgrade packages."
    exit 1
fi
set -e
sudo apt install -y python3-pip python3-dev libpq-dev postgresql postgresql-contrib nginx curl
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install required packages."
    exit 1
fi

# Create the directory structure
echo -e "\e[38;5;72m[INFO]\e[0m Creating project directory structure..."
mkdir -m 755 -p \
    "${project_path}/docker" \
    "${project_path}/log/nginx" \
    "${project_path}/conf/"{nginx,gunicorn,env_vars} \
    "${project_path}/${project_name}/"{apps,templates,jinja2,requirements,staticfiles} \
    "${project_path}/${project_name}/static/"{css,js,images,admin} \
    "${project_path}/${project_name}/media/uploads"

# Create requirements directory and base files
echo -e "\e[38;5;72m[INFO]\e[0m Creating requirements files..."
cat > "${project_path}/${project_name}/requirements/base.in" << EOL
# Main framework
Django>=5.0,<5.1  # https://www.djangoproject.com/

# PostgreSQL driver
psycopg[c]>=3.2.6  # https://github.com/psycopg/psycopg (supports C bindings for performance)

# Environment variables management
django-environ>=0.12.0  # https://github.com/joke2k/django-environ

# WSGI server
gunicorn>=23.0.0  # https://github.com/benoitc/gunicorn

# Templating
jinja2>=3.1.2  # https://github.com/pallets/jinja (Jinja2 templating engine)
EOL

cat > "${project_path}/${project_name}/requirements/local.in" << EOL
-r base.in

# Development tools
ipython>=8.14.0  # https://github.com/ipython/ipython
django-debug-toolbar>=5.1.0  # https://github.com/jazzband/django-debug-toolbar
django-extensions>=3.2.3  # https://github.com/django-extensions/django-extensions

# Code quality
ruff>=0.11.2  # https://github.com/astral-sh/ruff (modern linter and formatter)
coverage>=7.7.1  # https://github.com/nedbat/coveragepy (test coverage)
mypy>=1.15.0  # https://github.com/python/mypy (static type checking)
django-stubs>=5.1.3  # https://github.com/typeddjango/django-stubs (type hints for Django)

# Testing
pytest>=8.3.5  # https://github.com/pytest-dev/pytest
pytest-django>=4.10.0  # https://github.com/pytest-dev/pytest-django
factory-boy>=3.3.2  # https://github.com/FactoryBoy/factory_boy (fixtures for testing)
EOL

cat > "${project_path}/${project_name}/requirements/production.in" << EOL
-r base.in

# Security
django-allauth[mfa]>=65.4.1  # https://github.com/pennersr/django-allauth (authentication)
argon2-cffi>=23.1.0  # https://github.com/hynek/argon2_cffi (password hashing)

# Caching
django-redis>=5.4.0  # https://github.com/jazzband/django-redis (Redis caching)

# Performance
django-storages[s3]>=1.14.5  # https://github.com/jschneier/django-storages (S3 storage)
whitenoise>=6.8.0  # https://github.com/evansd/whitenoise (static file serving)

# Monitoring
sentry-sdk>=2.0.0  # https://github.com/getsentry/sentry-python (error tracking)
EOL

# Create log files with proper permissions
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/access.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/error.log"
sudo install -m 664 -o "${USER}" -g www-data /dev/null "${project_path}/log/gunicorn.log"
sudo install -m 664 -o "${USER}" -g www-data /dev/null "${project_path}/log/django.log"

# Create Docker files
echo -e "\e[38;5;72m[INFO]\e[0m Creating Docker configuration files..."
install -m 664 /dev/null "${project_path}/docker-compose.yml"
cat > "${project_path}/docker-compose.yml" << EOL
services:
  django:
    container_name: django
    build:
      context: .
      dockerfile: docker/Dockerfile.django
    ports:
      - "8000:8000"
    volumes:
      - .:/app
      - ./media:/app/media
    env_file:
      - conf/env_vars/production.env
    depends_on:
      - postgres
      - redis
    networks:
      - backend
    restart: unless-stopped

  postgres:
    image: postgres:17
    container_name: postgres
    environment:
      - POSTGRES_DB=${project_name}_db
      - POSTGRES_USER=${project_name}_user
      - POSTGRES_PASSWORD=${project_name}_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - backend
    restart: unless-stopped

  nginx:
    container_name: nginx
    build:
      context: .
      dockerfile: docker/Dockerfile.nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./media:/app/media:ro
      - ./static:/app/staticfiles:ro
    depends_on:
      - django
    networks:
      - frontend
      - backend
    restart: unless-stopped

  redis:
    image: redis:7
    container_name: redis
    ports:
      - "6379:6379"
    networks:
      - backend
    restart: unless-stopped

volumes:
  postgres_data:
    name: ${project_name}_postgres_data

networks:
  frontend:
    name: ${project_name}_frontend
  backend:
    name: ${project_name}_backend
EOL

install -m 664 /dev/null "${project_path}/docker/Dockerfile.django"
cat > "${project_path}/docker/Dockerfile.django" << EOL
# Stage 1: Base build stage
FROM python:3.11-slim AS builder

# Install build dependencies for psycopg[c] and uv
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy the project directory
COPY ${project_name} /app/${project_name}/

# Install uv and dependencies using uv directly to system Python
RUN pip install --no-cache-dir uv && \
    uv pip install --system --no-cache-dir -r /app/${project_name}/requirements/production.txt

# Stage 2: Production stage
FROM python:3.11-slim

# Set environment variables to optimize Python
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install runtime dependencies for psycopg
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN groupadd -r app-user && useradd -r -g app-user -u 1000 app-user

# Set the working directory
WORKDIR /app

# Copy installed dependencies and binaries from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages/ /usr/local/lib/python3.11/site-packages/
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /app /app

# Copy entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set ownership and switch to non-root user
RUN chown -R app-user:app-user /app
USER app-user

# Start the application using Gunicorn
ENTRYPOINT ["/entrypoint.sh"]
EOL

install -m 664 /dev/null "${project_path}/docker/Dockerfile.nginx"
cat > "${project_path}/docker/Dockerfile.nginx" << EOL
FROM nginx:stable-alpine

# Copy the main nginx configuration file
COPY conf/nginx/nginx.conf /etc/nginx/nginx.conf

# Copy the additional configuration file for virtual hosts
COPY conf/nginx/docker.conf /etc/nginx/conf.d/

# Set ownership for the nginx configuration directory
RUN chown -R nginx:nginx /etc/nginx/conf.d/

# Create directories for nginx logs and cache
RUN mkdir -p /var/log/nginx /var/cache/nginx

# Set ownership for the log and cache directories
RUN chown -R nginx:nginx /var/log/nginx /var/cache/nginx

# Switch to the nginx user
USER nginx

# Expose ports 80 (HTTP) and 443 (HTTPS) for nginx access
EXPOSE 80 443
EOL

install -m 755 /dev/null "${project_path}/docker/entrypoint.sh"
cat > "${project_path}/docker/entrypoint.sh" << EOL
#!/bin/sh

echo "Applying database migrations..."
python ${project_name}/manage.py migrate --noinput

echo "Collecting static files..."
python ${project_name}/manage.py collectstatic --noinput

echo "Starting Gunicorn..."
exec gunicorn --chdir ${project_name} config.wsgi:application \\
    --bind 0.0.0.0:8000 \\
    --workers 3 \\
    --timeout 120 \\
    --max-requests 1000 \\
    --access-logfile - \\
    --error-logfile - \\
    --log-level info
EOL

# Configure environment variables
echo -e "\e[38;5;72m[INFO]\e[0m Configuring environment variables..."

# Create local environment file with proper permissions
install -m 644 /dev/null "${project_path}/conf/env_vars/local.env"
cat > "${project_path}/conf/env_vars/local.env" << EOL
DEBUG=True
SECRET_KEY=
ALLOWED_HOSTS=${project_domain},127.0.0.1
DJANGO_SETTINGS_MODULE=config.settings.local

# PostgreSQL settings
DATABASE_URL=postgres://${project_name}_user:${project_name}_password@localhost:5432/${project_name}_db
EOL

 # Create production environment file with proper permissions
install -m 644 /dev/null "${project_path}/conf/env_vars/production.env"
cat > "${project_path}/conf/env_vars/production.env" << EOL
DEBUG=False
SECRET_KEY=
ALLOWED_HOSTS=${project_domain}
DJANGO_SETTINGS_MODULE=config.settings.production

# PostgreSQL settings
DATABASE_URL=postgres://${project_name}_user:${project_name}_password@postgres:5432/${project_name}_db
CONN_MAX_AGE=60

# Redis settings
REDIS_URL=redis://redis:6379/1

# Email settings
EMAIL_HOST=smtp.your-email.com
EMAIL_PORT=587
EMAIL_HOST_USER=your-email@example.com
EMAIL_HOST_PASSWORD=your-email-password
EOL

# Create PostgreSQL user and database
echo -e "\e[38;5;72m[INFO]\e[0m Creating PostgreSQL user and database..."

# Create user using PL/pgSQL
sudo -u postgres psql -q <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${project_name}_user') THEN
        CREATE USER ${project_name}_user WITH PASSWORD '${project_name}_password';
        ALTER ROLE ${project_name}_user SET client_encoding TO 'utf8';
        ALTER ROLE ${project_name}_user SET default_transaction_isolation TO 'read committed';
        ALTER ROLE ${project_name}_user SET timezone TO 'UTC';
        RAISE NOTICE 'User ${project_name}_user created with settings.';
    ELSE
        RAISE NOTICE 'User ${project_name}_user already exists. Skipping creation and settings.';
    END IF;
END \$\$;
EOF
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create PostgreSQL user ${project_name}_user."
    exit 1
fi

# Check if the database exists and create it if it doesn't
if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "${project_name}_db"; then
    sudo -u postgres psql -q -c "CREATE DATABASE ${project_name}_db WITH OWNER ${project_name}_user;"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create database ${project_name}_db."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Database ${project_name}_db created with privileges."
else
    echo -e "\e[38;5;208m[WARNING]\e[0m Database ${project_name}_db already exists. Skipping creation."
fi

# Grant privileges
sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE ${project_name}_db TO ${project_name}_user;"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to grant privileges on database ${project_name}_db."
    exit 1
fi

# Create .gitignore file
install -m 644 /dev/null "${project_path}/.gitignore"
cat > "${project_path}/.gitignore" << EOL
# Python
__pycache__/
*.py[cod]
*.so
*.egg
*.egg-info/
dist/
build/
eggs/
parts/
bin/
var/
sdist/
develop-eggs/
.installed.cfg
.Python
*.manifest
*.spec
pip-log.txt
pip-delete-this-directory.txt

# Virtual Environment
env/
venv/
.venv/
*.env
.python-version

# Django
*.log
*.pot
*.pyc
*.pyo
*.pyd
*.sqlite3
*.db
.static_storage/
local_settings.py
db.sqlite3
db.sqlite3-journal

# Media and Static files
media/
staticfiles/
!static/

# Docker
docker-compose*.yml
*.env
!docker-compose.yml

# IDE
.idea/
.vscode/
*.swp
*.swo
*~
.project
.pydevproject
.settings/
*.sublime-workspace
*.sublime-project

# Coverage / Testing
.coverage
.tox/
.coverage.*
.cache/
nosetests.xml
coverage.xml
*.cover
.hypothesis/
.pytest_cache/
htmlcov/

# OS generated files
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db
Desktop.ini

# Requirements
requirements/*.txt
!requirements/base.txt
!requirements/local.txt
!requirements/production.txt

# Entire directories
conf/
env/
log/

# Jinja2
jinja2/*.pyc
jinja2/__pycache__/
EOL

# Create .dockerignore file
install -m 644 /dev/null "${project_path}/.dockerignore"
cat > "${project_path}/.dockerignore" << EOL
# Git
.git
.gitignore
.gitattributes

# Python
*.pyc
*.pyo
*.pyd
__pycache__/
*.so
*.egg
*.egg-info/
dist/
build/
eggs/
parts/
bin/
var/
sdist/
develop-eggs/
.installed.cfg
.Python
pip-log.txt
pip-delete-this-directory.txt

# Testing and Coverage
.pytest_cache/
.coverage
htmlcov/
.tox/
.nox/
.hypothesis/
.pytest_cache/
coverage.xml
nosetests.xml

# Environment
.env
env/
venv/
.venv/
.python-version

# Project specific
log/*
media/*
static/*
staticfiles/*
*.sqlite3
*.db
db.sqlite3-journal

# Docker
.docker
docker-compose*.yml
Dockerfile*
!docker/Dockerfile.local
!docker/Dockerfile.production

# IDE
.idea/
.vscode/
*.swp
*.swo
*~
.project
.settings/
*.sublime-workspace
*.sublime-project

# OS generated
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db
Desktop.ini

# Documentation
docs/
*.md
!README.md

# Node
node_modules/
npm-debug.log
yarn-debug.log
yarn-error.log

# Project specific - conf directory
conf/env_vars/*.env

# Temporary files
*.swp
*~
*.bak
*.tmp
EOL

# Check if uv is installed, install it if not
if ! command -v uv &> /dev/null; then
    echo -e "\e[38;5;72m[INFO]\e[0m Installing uv..."
    python3 -m pip install uv
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install uv."
        exit 1
    fi
fi

# Set up Python virtual environment
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Python virtual environment..."
cd "${project_path}"
uv venv env
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create virtual environment."
    exit 1
fi

# Add DJANGO_SETTINGS_MODULE to the virtual environment's activate script
echo -e "\e[38;5;72m[INFO]\e[0m Adding DJANGO_SETTINGS_MODULE to activate script..."
echo "export DJANGO_SETTINGS_MODULE=config.settings.${environment}" >> "${project_path}/env/bin/activate"
source env/bin/activate

# Upgrade pip
echo -e "\e[38;5;72m[INFO]\e[0m Upgrading pip..."
pip install --upgrade pip
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to upgrade pip."
    exit 1
fi

# Compile requirements files
echo -e "\e[38;5;72m[INFO]\e[0m Compiling requirements files..."

uv pip compile ${project_name}/requirements/base.in --no-emit-options --output-file ${project_name}/requirements/base.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile base.txt requirements."
    exit 1
fi
uv pip compile ${project_name}/requirements/local.in --no-emit-options --output-file ${project_name}/requirements/local.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile local.txt requirements."
    exit 1
fi
uv pip compile ${project_name}/requirements/production.in --no-emit-options --output-file ${project_name}/requirements/production.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile production.txt requirements."
    exit 1
fi

# Install dependencies based on environment
echo -e "\e[38;5;72m[INFO]\e[0m Installing ${environment} dependencies..."
uv pip sync ${project_name}/requirements/${environment}.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install ${environment} dependencies."
    exit 1
fi

# Create Django project
echo -e "\e[38;5;72m[INFO]\e[0m Creating Django project..."
django-admin startproject config "${project_name}"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create Django project."
    exit 1
fi
cd "${project_name}"

# Create applications directory
echo -e "\e[38;5;72m[INFO]\e[0m Setting up applications directory..."
touch apps/__init__.py

# Create Jinja2 environment configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating Jinja2 environment configuration..."
cat <<EOF > config/jinja2.py
from django.templatetags.static import static
from django.urls import reverse
from jinja2 import Environment

def environment(**options):
    env = Environment(**options)
    env.globals.update({
        'static': static,
        'url': reverse,
    })
    return env
EOF

# Create settings directory and split settings files
echo -e "\e[38;5;72m[INFO]\e[0m Creating settings directory and split settings files..."
mkdir -m 755 -p config/settings
install -m 644 /dev/null config/settings/__init__.py
install -m 644 /dev/null config/settings/base.py
install -m 644 /dev/null config/settings/local.py
install -m 644 /dev/null config/settings/production.py
install -m 644 /dev/null config/settings/test.py

# Populate settings/base.py
cat > config/settings/base.py << EOF
import sys
from pathlib import Path
from django.utils.translation import gettext_lazy as _
import environ

# Build paths inside the project like this: BASE_DIR / 'subdir'.
BASE_DIR = Path(__file__).resolve().parents[3]

env = environ.Env()

# Application definition - Lists of apps for Django, third-party, and local use
DJANGO_APPS = [
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.sites',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'django.contrib.admin',
]

THIRD_PARTY_APPS = [
    # 'crispy_forms',
]

LOCAL_APPS = [
    # 'apps.blog',
]

INSTALLED_APPS = DJANGO_APPS + THIRD_PARTY_APPS + LOCAL_APPS

# Middleware configuration - Security and session handling
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'

# Template engines - Jinja2 and Django templates configuration
TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.jinja2.Jinja2',
        'DIRS': [BASE_DIR / '${project_name}/jinja2'],
        'APP_DIRS': True,
        'OPTIONS': {
            'environment': 'config.jinja2.environment',
        },
    },
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / '${project_name}/templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'

# Password validation - Rules for secure passwords
AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# Internationalization - Language and timezone settings
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True

LOCALE_PATHS = [BASE_DIR / '${project_name}/locale']
LANGUAGES = [
    ('en', _('English')),
    # ('ru', _('Russian')),
]

# Static files (CSS, JavaScript, Images) - Paths and finders
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / '${project_name}/staticfiles'
STATICFILES_DIRS = [BASE_DIR / '${project_name}/static']
STATICFILES_FINDERS = [
    'django.contrib.staticfiles.finders.FileSystemFinder',
    'django.contrib.staticfiles.finders.AppDirectoriesFinder',
]

MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / '${project_name}/media'

# Security settings - Basic protections against common vulnerabilities
SESSION_COOKIE_HTTPONLY = True
CSRF_COOKIE_HTTPONLY = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'

# Default primary key field type - For database models
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# Admin - Contact information for error notifications
STAFF_ALEXEY = ('Alexey', 'aleksey.sundyrev@gmail.com')
ADMINS = (STAFF_ALEXEY)
MANAGERS = ADMINS

# Sites framework - Default site ID for django.contrib.sites
SITE_ID = 1

# Caching - Base configuration with multiple cache options
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.dummy.DummyCache',
    },
    'localmem': {
        'BACKEND': 'django.core.cache.backends.locmem.LocMemCache',
        'LOCATION': '',
    },
}

# Logging - Basic console logging setup
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {
            'level': 'INFO',
            'class': 'logging.StreamHandler',
            'stream': sys.stdout,
            'formatter': 'verbose',
        },
    },
    'root': {
        'handlers': ['console'],
        'level': 'INFO',
    },
}
EOF

# Populate settings/local.py
cat > config/settings/local.py << EOF
from .base import *

env.read_env(env_file=BASE_DIR / 'conf/env_vars/local.env')
SECRET_KEY = env('SECRET_KEY')

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = True

ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=['localhost', '127.0.0.1'])

# Database - Configuration for local development
DATABASES = {
    'default': env.db('DATABASE_URL', default='postgres:///testapp'),
}
DATABASES['default']['ATOMIC_REQUESTS'] = True

# Development tools - Debugging and extension utilities
INTERNAL_IPS = ['127.0.0.1']

INSTALLED_APPS += [
    'debug_toolbar',
    'django_extensions',
]

MIDDLEWARE += [
    'debug_toolbar.middleware.DebugToolbarMiddleware',
]

DEBUG_TOOLBAR_CONFIG = {
    'SHOW_TEMPLATE_CONTEXT': True,
    'DISABLE_PANELS': [
        'debug_toolbar.panels.redirects.RedirectsPanel',
        'debug_toolbar.panels.profiling.ProfilingPanel',
    ],
}

# Email settings - Console output for development
EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'

# Caching - Using 'default' from base.py (DummyCache)
# Uncomment this line to use LocMemCache for local development
# CACHES = {'default': CACHES['localmem']}

# Logging - Detailed logging for development debugging
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {message}',
            'style': '{',
        },
        'simple': {
            'format': '{levelname} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {
            'level': 'DEBUG',
            'class': 'logging.StreamHandler',
            'formatter': 'simple',
            'stream': sys.stdout,
        },
        'file': {
            'level': 'DEBUG',
            'class': 'logging.FileHandler',
            'filename': BASE_DIR / 'log/django.log',
            'formatter': 'verbose',
        },
    },
    'root': {
        'handlers': ['console', 'file'],
        'level': 'DEBUG',
    },
    'loggers': {
        'django': {
            'handlers': ['console', 'file'],
            'level': 'INFO',
            'propagate': True,
        },
        'django.db.backends': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
        'django.utils.autoreload': {
            'handlers': ['console'],
            'level': 'WARNING',
            'propagate': False,
        },
    },
}
EOF

# Populate settings/production.py
cat > config/settings/production.py << EOF
from .base import *

env.read_env(env_file=BASE_DIR / 'conf/env_vars/production.env')
SECRET_KEY = env('SECRET_KEY')

# SECURITY WARNING: don't run with debug turned on in production!
DEBUG = False

ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=['${project_domain}'])

# Database - Configuration for production with persistent connections
DATABASES = {
    'default': env.db('DATABASE_URL'),
}
DATABASES['default']['ATOMIC_REQUESTS'] = True
DATABASES['default']['CONN_MAX_AGE'] = env.int('CONN_MAX_AGE', default=60)

# Security settings - Enhanced protections for production
SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
SESSION_COOKIE_NAME = '__Secure-sessionid'
CSRF_COOKIE_SECURE = True
CSRF_COOKIE_NAME = '__Secure-csrftoken'
SECURE_BROWSER_XSS_FILTER = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = env.bool('DJANGO_SECURE_HSTS_PRELOAD', default=True)
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

# Email settings - SMTP configuration for production
EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST = env('EMAIL_HOST')
EMAIL_PORT = env('EMAIL_PORT')
EMAIL_HOST_USER = env('EMAIL_HOST_USER')
EMAIL_HOST_PASSWORD = env('EMAIL_HOST_PASSWORD')
EMAIL_USE_TLS = True
DEFAULT_FROM_EMAIL = 'your@domain.com'

# Caching - Redis configuration for performance
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.redis.RedisCache',
        'LOCATION': env('REDIS_URL', default='redis://localhost:6379/1'),
        'OPTIONS': {
            'IGNORE_EXCEPTIONS': True,
        },
    }
}

# Logging - Production logging with error notifications
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'filters': {'require_debug_false': {'()': 'django.utils.log.RequireDebugFalse'}},
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {
            'level': 'INFO',
            'class': 'logging.StreamHandler',
            'stream': sys.stdout,
            'formatter': 'verbose',
        },
        'mail_admins': {
            'level': 'ERROR',
            'filters': ['require_debug_false'],
            'class': 'django.utils.log.AdminEmailHandler',
        },
    },
    'root': {
        'handlers': ['console'],
        'level': 'INFO',
    },
    'loggers': {
        'django.request': {
            'handlers': ['mail_admins'],
            'level': 'ERROR',
            'propagate': True,
        },
    },
}

# Static files - Storage configuration for production
STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'
EOF

# Populate settings/test.py
cat > config/settings/test.py << EOF
from .base import *

SECRET_KEY = env('SECRET_KEY')
TEST_RUNNER = 'django.test.runner.DiscoverRunner'
PASSWORD_HASHERS = ['django.contrib.auth.hashers.MD5PasswordHasher']
EMAIL_BACKEND = 'django.core.mail.backends.locmem.EmailBackend'
CACHES = {
    'default': CACHES['localmem'],  # Use LocMemCache from base.py for testing
}
EOF

# Remove the original settings.py as it’s no longer needed
echo -e "\e[38;5;72m[INFO]\e[0m Removing original settings.py..."
if [ -f config/settings.py ]; then
    rm -f config/settings.py
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to remove original settings.py."
        exit 1
    fi
else
    echo -e "\e[38;5;208m[WARNING]\e[0m Original settings.py not found, skipping removal."
fi

# Generate a secure SECRET_KEY and update .env files
echo -e "\e[38;5;72m[INFO]\e[0m Generating a secure SECRET_KEY and updating .env files..."
SECRET_KEY=$(python -c "import secrets; print(secrets.token_urlsafe(50))")

# Escape special characters in SECRET_KEY for sed
SECRET_KEY_ESCAPED=$(echo "$SECRET_KEY" | sed 's/[&/\]/\\&/g')

# Update .env .env files with the new SECRET_KEY in quotes
sed -i "s/^SECRET_KEY=.*/SECRET_KEY='${SECRET_KEY_ESCAPED}'/" "${project_path}/conf/env_vars/local.env"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update SECRET_KEY in local.env."
    exit 1
fi
sed -i "s/^SECRET_KEY=.*/SECRET_KEY='${SECRET_KEY_ESCAPED}'/" "${project_path}/conf/env_vars/production.env"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update SECRET_KEY in production.env."
    exit 1
fi

# Update settings/urls.py
urls_path=config/urls.py
sed -i "1,/from django.urls import path/c\from django.contrib import admin\nfrom django.urls import path, include\nfrom django.conf import settings" "${urls_path}"
echo "" >> "${urls_path}"
# Add debug toolbar urls settings
cat >> "${urls_path}" << 'EOF'
if settings.DEBUG:
    urlpatterns.append(path('__debug__/', include('debug_toolbar.urls')))
EOF

# Load environment variables before collecting static files
echo -e "\e[38;5;72m[INFO]\e[0m Loading environment variables from ${environment}.env..."
export $(grep -v '^#' "${project_path}/conf/env_vars/${environment}.env" | xargs)

# Collect static files
echo -e "\e[38;5;72m[INFO]\e[0m Collecting static files..."
python manage.py collectstatic --noinput
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to collect static files."
    exit 1
fi

# Configure Gunicorn
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Gunicorn configuration..."
gunicorn_socket="${project_path}/conf/gunicorn/${project_name}.gunicorn.socket"
gunicorn_service="${project_path}/conf/gunicorn/${project_name}.gunicorn.service"

cat <<EOF > "${gunicorn_socket}"
[Unit]
Description=gunicorn socket

[Socket]
ListenStream=/run/${project_name}.gunicorn.sock

[Install]
WantedBy=sockets.target
EOF
chmod 644 "${gunicorn_socket}"

cat <<EOF > "${gunicorn_service}"
[Unit]
Description=gunicorn daemon
Requires=${project_name}.gunicorn.socket
After=network.target

[Service]
User=${USER}
Group=www-data
WorkingDirectory=${project_path}/${project_name}
EnvironmentFile=${project_path}/conf/env_vars/${environment}.env
ExecStart=${project_path}/env/bin/gunicorn \\
    --access-logfile ${project_path}/log/gunicorn.log \\
    --error-logfile ${project_path}/log/gunicorn.log \\
    --capture-output \\
    --workers 3 \\
    --bind unix:/run/${project_name}.gunicorn.sock \\
    config.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${gunicorn_service}"

sudo ln -s "${gunicorn_service}" "/etc/systemd/system/${project_name}.gunicorn.service"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create symlink for Gunicorn service."
    exit 1
fi
sudo ln -s "${gunicorn_socket}" "/etc/systemd/system/${project_name}.gunicorn.socket"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create symlink for Gunicorn socket."
    exit 1
fi
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload systemd daemon."
    exit 1
fi

# Start and enable Gunicorn service with status check
sudo systemctl start "${project_name}.gunicorn.service"
if ! sudo systemctl is-active "${project_name}.gunicorn.service" > /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to start Gunicorn service."
    exit 1
fi
sudo systemctl enable "${project_name}.gunicorn.service"

# Start and enable Gunicorn socket with status check
sudo systemctl start "${project_name}.gunicorn.socket"
if ! sudo systemctl is-active "${project_name}.gunicorn.socket" > /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to start Gunicorn socket."
    exit 1
fi
sudo systemctl enable "${project_name}.gunicorn.socket"

# Configure Nginx
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Nginx configuration..."
nginx_conf="${project_path}/conf/nginx/nginx.conf"
cat <<EOF > "${nginx_conf}"
worker_processes auto;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

pid /var/cache/nginx/nginx.pid;

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
chmod 644 "${nginx_conf}"
sudo cp "${nginx_conf}" /etc/nginx/nginx.conf
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to copy Nginx configuration."
    exit 1
fi
sudo chmod 644 /etc/nginx/nginx.conf
sudo mkdir -p /var/cache/nginx
sudo chown www-data:www-data /var/cache/nginx

project_nginx_conf="${project_path}/conf/nginx/${project_name}.conf"
cat <<EOF > "${project_nginx_conf}"
server {
    listen 80;
    server_name ${project_domain};

    access_log ${project_path}/log/nginx/access.log;
    error_log ${project_path}/log/nginx/error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location /static/ {
        alias ${project_path}/${project_name}/staticfiles/;
        add_header Cache-Control "public";
        expires 7d;
        access_log off;
    }

    location /media/ {
        alias ${project_path}/${project_name}/media/;
        add_header Cache-Control "public";
        expires 30d;
    }

    location / {
        proxy_pass http://unix:/run/${project_name}.gunicorn.sock;
        error_page 502 = @fallback;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        send_timeout 60s;

        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        
        client_max_body_size 100M;
    }

    location @fallback {
        proxy_pass http://127.0.0.1:8000;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
chmod 644 "${project_nginx_conf}"

docker_nginx_conf="${project_path}/conf/nginx/docker.conf"
cat <<EOF > "${docker_nginx_conf}"
server {
    listen 80;
    server_name ${project_domain};

    error_log /dev/stderr warn;
    access_log /dev/stdout;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # Content Security Policy (CSP) to prevent XSS and other attacks.
    # - 'self' allows loading resources only from your domain.
    # - 'data:' allows embedded images (e.g., base64).
    # Adjust this policy based on your app's requirements (e.g., external APIs, CDNs).
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:;";

    # HTTP Strict Transport Security (HSTS) to enforce HTTPS.
    # - Uncomment this ONLY after enabling HTTPS.
    # - 'max-age=31536000' enforces HTTPS for 1 year.
    # - 'includeSubDomains' applies HTTPS to all subdomains.
    # - 'preload' allows adding your domain to the HSTS preload list (e.g., Chrome).
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload";

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location /static/ {
        alias /app/staticfiles/;
        add_header Cache-Control "public";
        expires 1y;
        access_log off;
    }

    location /media/ {
        alias /app/media/;
        add_header Cache-Control "public";
        expires 30d;
    }

    location / {
        # Forward requests to Django application
        proxy_pass http://django:8000;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        send_timeout 60s;

        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";

        client_max_body_size 100M;
    }
}
EOF
chmod 644 "${docker_nginx_conf}"

# Specify the correct PID file for Nginx in systemd
sudo mkdir -p /etc/systemd/system/nginx.service.d
echo -e "[Service]\nPIDFile=/var/cache/nginx/nginx.pid" | sudo tee /etc/systemd/system/nginx.service.d/override.conf > /dev/null

# Reload systemd to apply changes
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload systemd daemon for Nginx."
    exit 1
fi

# Create a symbolic link for Nginx configuration
if [[ ! -f "/etc/nginx/sites-enabled/${project_name}.conf" ]]; then
    sudo ln -sf "${project_nginx_conf}" "/etc/nginx/sites-enabled/${project_name}.conf"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create symbolic link for Nginx configuration."
        exit 1
    fi
fi

# Validate Nginx configuration before restarting
if sudo nginx -t; then
    echo -e "\e[38;5;72m[INFO]\e[0m Restarting Nginx..."
    sudo systemctl restart nginx
    if ! sudo systemctl is-active nginx > /dev/null; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to restart Nginx service."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Nginx configuration test failed!"
    exit 1
fi

echo -e "\e[38;5;48m[SUCCESS]\e[0m Django project initialized, keep up the good work!"