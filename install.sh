#!/bin/bash

# Check if pyenv is installed
if ! command -v pyenv &> /dev/null; then
    echo -e "\e[31m[ERROR]\e[0m pyenv is not installed. Please install it before proceeding."
    exit 1
fi

# Variables
default_python_interpreter=$(which python3)
project_domain=""
project_path=$(dirname "$(realpath "$0")")
project_name=""
environment=""

# Function to validate environment input
validate_environment() {
    local env=$1
    env=$(echo "$env" | tr '[:upper:]' '[:lower:]')

    if [[ "$env" != "dev" && "$env" != "development" && "$env" != "production" ]]; then
        echo "Invalid environment. Please choose 'development' or 'production'"
        return 1
    fi

    if [[ "$env" == "dev" || "$env" == "development" ]]; then
        echo "local"
    else
        echo "production"
    fi

    return 0
}

# Prompt for user input
read -e -p "Python interpreter (default: ${default_python_interpreter}): " base_python_interpreter
read -e -p "Your domain without protocol (e.g., example.com): " project_domain
read -e -p "Project name: " project_name

# Environment selection with validation
while true; do
    read -e -p $'Select environment (Development \e[36m[dev]\e[0m/Production): ' environment
    normalized_environment=$(validate_environment "$environment")
    if [[ $? -eq 0 ]]; then
        environment="$normalized_environment"
        break
    fi
done

# Set defaults if not provided
base_python_interpreter=${base_python_interpreter:-${default_python_interpreter}}

# Install necessary packages
echo -e "\e[32m[INFO]\e[0m Installing necessary packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-pip python3-dev libpq-dev postgresql postgresql-contrib nginx curl

# Create the directory structure
echo -e "\e[32m[INFO]\e[0m Creating project directory structure..."
mkdir -m 755 -p \
    "${project_path}/docker" \
    "${project_path}/log/nginx" \
    "${project_path}/conf/"{nginx,gunicorn,env_vars} \
    "${project_path}/${project_name}/"{apps,templates,jinja2,requirements,staticfiles} \
    "${project_path}/${project_name}/static/"{css,js,images,admin} \
    "${project_path}/${project_name}/media/uploads"

# Create requirements directory and base files
echo -e "\e[32m[INFO]\e[0m Creating requirements files..."
cat > "${project_path}/${project_name}/requirements/base.in" << EOL
# Main framework
Django>=5.0,<5.1

# PostgreSQL driver
psycopg2-binary>=2.9.0

# Environment variables management
django-environ>=0.11.2

# Templating
Jinja2>=3.1.0

# WSGI server
gunicorn>=20.1.0
EOL

cat > "${project_path}/${project_name}/requirements/local.in" << EOL
-r base.in

# Development tools
ipython>=8.0.0
django-debug-toolbar>=4.0.0
django-extensions>=3.2.0

# Code quality
flake8>=6.0.0
black>=23.0.0
isort>=5.12.0
mypy>=1.0.0

# Testing
pytest>=7.0.0
pytest-django>=4.5.0
pytest-cov>=4.0.0
factory_boy>=3.2.0
Faker>=18.0.0
EOL

cat > "${project_path}/${project_name}/requirements/production.in" << EOL
-r base.in

# Security
django-security>=0.12.0
django-axes>=6.0.0

# Monitoring
sentry-sdk>=1.0.0

# Caching
django-redis>=5.2.0

# Performance
django-storages>=1.13.0
whitenoise>=6.4.0
EOL

# Create log files with proper permissions
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/access.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/error.log"
sudo install -m 664 -o "${USER}" -g www-data /dev/null "${project_path}/log/gunicorn.log"
sudo install -m 664 -o "${USER}" -g www-data /dev/null "${project_path}/log/django.log"

# Create Docker files
echo -e "\e[32m[INFO]\e[0m Creating Docker configuration files..."
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
      - database
    networks:
      - backend
    restart: unless-stopped

  database:
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

# Create the app directory
RUN mkdir /app

# Set the working directory
WORKDIR /app

COPY ${project_name}/requirements/base.txt ${project_name}/requirements/production.txt /app/${project_name}/requirements/

# Install dependencies first for caching benefits
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /app/${project_name}/requirements/production.txt

# Stage 2: Production stage
FROM python:3.11-slim

# Set environment variables to optimize Python
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Create a non-root user
RUN groupadd -r app-user && useradd -r -g app-user -u 1000 app-user

# Set the working directory
WORKDIR /app

# Copy the Python dependencies from the builder stage
COPY --from=builder /usr/local/lib/python3.11/site-packages/ /usr/local/lib/python3.11/site-packages/
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /app /app

COPY docker/entrypoint.sh /entrypoint.sh
# Make entry file executable
RUN chmod +x /entrypoint.sh

RUN chown -R app-user:app-user /app

# Switch to non-root user
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

install -m 664 /dev/null "${project_path}/docker/entrypoint.sh"
cat > "${project_path}/docker/entrypoint.sh" << EOL
#!/bin/sh

echo "Applying database migrations..."
python ${project_name}/manage.py migrate --noinput

echo "Collecting static files..."
python ${project_name}/manage.py collectstatic --noinput

echo "Starting Gunicorn..."
exec gunicorn --chdir ${project_name} config.wsgi:application \
    --bind 0.0.0.0:8000 \
    --workers 3 \
    --timeout 120 \
    --max-requests 1000 \
    --access-logfile - \
    --error-logfile - \
    --log-level info
EOL

# Configure environment variables
echo -e "\e[32m[INFO]\e[0m Configuring environment variables..."

# Create local environment file with proper permissions
install -m 644 /dev/null "${project_path}/conf/env_vars/local.env"
cat > "${project_path}/conf/env_vars/local.env" << EOL
DEBUG=True
#SECRET_KEY=insert-your-secret-key-here
ALLOWED_HOSTS=${project_domain},localhost

# PostgreSQL settings
POSTGRES_DB=${project_name}_db
POSTGRES_USER=${project_name}_user
POSTGRES_PASSWORD=${project_name}_password
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
EOL

 # Create production environment file with proper permissions
install -m 644 /dev/null "${project_path}/conf/env_vars/production.env"
cat > "${project_path}/conf/env_vars/production.env" << EOL
DEBUG=False
#SECRET_KEY=insert-your-secret-key-here
ALLOWED_HOSTS=${project_domain}

# PostgreSQL settings
POSTGRES_DB=${project_name}_db
POSTGRES_USER=${project_name}_user
POSTGRES_PASSWORD=${project_name}_password
POSTGRES_HOST=database
POSTGRES_PORT=5432

# Redis settings
#REDIS_URL

# Email settings
#EMAIL_HOST
#EMAIL_PORT
#EMAIL_HOST_USER
#EMAIL_HOST_PASSWORD
EOL

# Create PostgreSQL user and database
echo -e "\e[32m[INFO]\e[0m Creating PostgreSQL user and database..."
sudo -u postgres psql <<EOF
CREATE USER ${project_name}_user WITH PASSWORD '${project_name}_password';
CREATE DATABASE ${project_name}_db WITH OWNER ${project_name}_user;
ALTER ROLE ${project_name}_user SET client_encoding TO 'utf8';
ALTER ROLE ${project_name}_user SET default_transaction_isolation TO 'read committed';
ALTER ROLE ${project_name}_user SET timezone TO 'UTC';
GRANT ALL PRIVILEGES ON DATABASE ${project_name}_db TO ${project_name}_user;
EOF

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
.env
env/
venv/
.venv/
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
static/
!static/.gitkeep

# Docker
docker-compose*.yml
.docker/
docker/
*.env

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

# Logs
log/*.log
*.log
npm-debug.log*
yarn-debug.log*
yarn-error.log*

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

# Set up Python virtual environment
echo -e "\e[32m[INFO]\e[0m Setting up Python virtual environment..."
cd "${project_path}"
${base_python_interpreter} -m venv env
source env/bin/activate

# Upgrade pip and install pip-tools
echo -e "\e[32m[INFO]\e[0m Upgrading pip and installing pip-tools..."
pip install --upgrade pip
pip install pip-tools

# Compile requirements files
echo -e "\e[32m[INFO]\e[0m Compiling requirements files..."
pip-compile ${project_name}/requirements/base.in --no-strip-extras --output-file ${project_name}/requirements/base.txt
pip-compile ${project_name}/requirements/local.in --no-strip-extras --output-file ${project_name}/requirements/local.txt
pip-compile ${project_name}/requirements/production.in --no-strip-extras --output-file ${project_name}/requirements/production.txt

# Install dependencies based on environment
echo -e "\e[32m[INFO]\e[0m Installing ${environment} dependencies..."
pip-sync ${project_name}/requirements/${environment}.txt

# Create Django project
echo -e "\e[32m[INFO]\e[0m Creating Django project..."
django-admin startproject config "${project_name}"
cd "${project_name}"

# Create applications directory
echo -e "\e[32m[INFO]\e[0m Setting up applications directory..."
touch apps/__init__.py

# Create Jinja2 environment configuration
echo -e "\e[32m[INFO]\e[0m Creating Jinja2 environment configuration..."
mkdir -m 755 -p config
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

# Update settings/base.py
echo -e "\e[32m[INFO]\e[0m Updating Django settings..."
settings_path=config/settings.py

# Update import section
sed -i "1,/from pathlib import Path/c\import sys\n\nimport environ\nfrom pathlib import Path" "${settings_path}"

# Update BASE_DIR definition
sed -i "s|BASE_DIR = Path(__file__).resolve().parent.parent|BASE_DIR = Path(__file__).resolve().parent.parent.parent\n\nenv = environ.Env()\nenv.read_env(env_file=BASE_DIR / 'conf/env_vars/${environment}.env')|" "${settings_path}"

# Add environment-based SECRET_KEY setting
sed -i "/SECRET_KEY =/a # SECRET_KEY= env('SECRET_KEY')" "${settings_path}"

# Update DEBUG setting
sed -i "s/DEBUG = True/DEBUG = env.bool('DEBUG', default=False)/" "${settings_path}"

# Update ALLOWED_HOSTS setting
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=\['localhost'\])/" "${settings_path}"

# Update STATIC and MEDIA settings
cat > config/settings_static.py << EOF
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / '${project_name}/staticfiles'
STATICFILES_DIRS = [
    BASE_DIR / '${project_name}/static',
]

MEDIA_URL = '/media/'
EOF

# Update MEDIA_ROOT setting depending on the environment
if [ "$environment" = "production" ]; then
    echo "MEDIA_ROOT = '/var/www/myproject/media/'" >> config/settings_static.py
else
    echo "MEDIA_ROOT = BASE_DIR / '${project_name}/media'" >> config/settings_static.py
fi
sed -i '
/^STATIC_URL = /r config/settings_static.py
/^STATIC_URL = /d
' "${settings_path}"
rm -f config/settings_static.py

# Update TEMPLATES setting
cat > config/settings_templates.py << EOF
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
EOF
sed -i '
/^TEMPLATES = \[/,/^]/{
/^TEMPLATES = \[/r config/settings_templates.py
d
}
' "${settings_path}"
rm -f config/settings_templates.py

# Update DATABASES setting
cat > config/settings_database.py << 'EOF'
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql_psycopg2',
        'NAME': env('POSTGRES_DB'),
        'USER': env('POSTGRES_USER'),
        'PASSWORD': env('POSTGRES_PASSWORD'),
        'HOST': env('POSTGRES_HOST', default='localhost'),
        'PORT': env('POSTGRES_PORT', default='5432'),
        'AUTOCOMMIT': True,
    }
}
EOF
sed -i '
/^DATABASES = {/,/^}/{
/^DATABASES = {/r config/settings_database.py
d
}
' "${settings_path}"
rm -f config/settings_database.py

echo "" >> "${settings_path}"
# Add logging configuration
cat >> "${settings_path}" << 'EOF'
if DEBUG:
    INTERNAL_IPS = ['127.0.0.1']
    
    INSTALLED_APPS += [
        'debug_toolbar',
        'django_extensions',
    ]
    MIDDLEWARE += [
        'debug_toolbar.middleware.DebugToolbarMiddleware',
    ]
    
    # Email settings for development
    EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'
    
    # Disabling caching
    CACHES = {
        'default': {
            'BACKEND': 'django.core.cache.backends.dummy.DummyCache',
        }
    }

    # Logging
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
                'filename': BASE_DIR / 'log/django_dev.log',
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
else:
    # Security settings
    # SECURE_SSL_REDIRECT = True
    # SESSION_COOKIE_SECURE = True
    # CSRF_COOKIE_SECURE = True
    # SECURE_BROWSER_XSS_FILTER = True
    # SECURE_CONTENT_TYPE_NOSNIFF = True
    # X_FRAME_OPTIONS = 'DENY'
    # SECURE_HSTS_SECONDS = 31536000
    # SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    # SECURE_HSTS_PRELOAD = True

    # Email settings
    # EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
    # EMAIL_HOST = env('EMAIL_HOST')
    # EMAIL_PORT = env('EMAIL_PORT')
    # EMAIL_HOST_USER = env('EMAIL_HOST_USER')
    # EMAIL_HOST_PASSWORD = env('EMAIL_HOST_PASSWORD')
    # EMAIL_USE_TLS = True
    # DEFAULT_FROM_EMAIL = 'your@domain.com'

    # Caching settings
    CACHES = {
        'default': {
            'BACKEND': 'django.core.cache.backends.redis.RedisCache',
            'LOCATION': env('REDIS_URL', default='redis://localhost:6379/1'),
        }
    }

    # Logging
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

    # Settings for static files
    STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'
EOF

# Collect static files
echo -e "\e[32m[INFO]\e[0m Collecting static files..."
python manage.py collectstatic --noinput

# Configure Gunicorn
echo -e "\e[32m[INFO]\e[0m Setting up Gunicorn configuration..."
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
ExecStart=${project_path}/env/bin/gunicorn \
    --access-logfile ${project_path}/log/gunicorn.log \
    --error-logfile ${project_path}/log/gunicorn.log \
    --capture-output \
    --workers 3 \
    --bind unix:/run/${project_name}.gunicorn.sock \
    config.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${gunicorn_service}"

sudo ln -s "${gunicorn_service}" "/etc/systemd/system/${project_name}.gunicorn.service"
sudo ln -s "${gunicorn_socket}" "/etc/systemd/system/${project_name}.gunicorn.socket"
sudo systemctl daemon-reload 

sudo systemctl start "${project_name}.gunicorn.service"
sudo systemctl enable "${project_name}.gunicorn.service"
sudo systemctl start "${project_name}.gunicorn.socket"
sudo systemctl enable "${project_name}.gunicorn.socket"

# Configure Nginx
echo -e "\e[32m[INFO]\e[0m Setting up Nginx configuration..."
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
        # Forward requests to Django application
        proxy_pass http://unix:/run/${project_name}.gunicorn.sock;

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

# Create a symbolic link for Nginx configuration
if [[ ! -f "/etc/nginx/sites-enabled/${project_name}.conf" ]]; then
    sudo ln -sf "${project_nginx_conf}" "/etc/nginx/sites-enabled/${project_name}.conf"
fi

# Validate Nginx configuration before restarting
if sudo nginx -t; then
    echo -e "\e[32m[INFO]\e[0m Restarting Nginx..."
    sudo systemctl restart nginx
else
    echo -e "\e[31m[ERROR]\e[0m Nginx configuration test failed!"
    exit 1
fi

echo -e "\e[32m[INFO]\e[0m Django project setup completed successfully."