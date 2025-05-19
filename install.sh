#!/bin/bash
set -e

# ============================================
# Script to initialize a Django project
# ============================================
# This script sets up a Django project with a predefined structure, installs
# dependencies using uv, configures PostgreSQL, Gunicorn, Nginx, and Docker, and
# initializes a Git repository. It supports both local and production environments,
# prompted via user input. The script creates configuration files, sets permissions,
# and ensures a secure setup with tools like Ruff, djlint, and pre-commit. Assumes
# uv is installed globally and Python 3.12 is pinned with `uv python pin 3.12`.

# Usage: ./install.sh
# No arguments are required; the script prompts for project domain, name, and
# environment (local or production).

# Check if python3 is installed
if ! command -v python3 &> /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Python3 is not installed or not found in PATH. Please install Python 3.12 and ensure it is accessible as 'python3'."
    exit 1
fi

# Check Python version
python_version=$(python3 --version | grep -oP '\d+\.\d+')
if [ "$python_version" != "3.12" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Python 3.12 is required, found $python_version."
    exit 1
fi

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Git is not installed. Please install it before proceeding."
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

# Validate project name format using regex pattern
if ! [[ "$project_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project name must contain only letters, numbers, hyphens, or underscores."
    exit 1
fi

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
            project_path="/opt/${project_name}App"
            break
            ;;
        *)
            echo -e "\e[38;5;196m[ERROR]\e[0m Invalid choice. Please enter \e[38;5;117m1\e[0m or \e[38;5;117m2\e[0m."
            ;;
    esac
done

# Set virtual environment path based on environment
if [ "$environment" = "local" ]; then
    venv_path="${project_path}/env"
else
    venv_path="${project_path}/env"
    sudo mkdir -m 755 -p "${project_path}"
    sudo chown www-data:www-data "${project_path}"
fi

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

# Check if the current user is in the www-data group
if ! groups "${USER}" | grep -qw 'www-data'; then
    echo -e "\e[38;5;208m[WARNING]\e[0m User ${USER} is not in the www-data group. Adding user..."
    sudo usermod -aG www-data "${USER}"
    echo -e "\e[38;5;196m[ERROR]\e[0m Please restart your session or run \e[38;5;223m'newgrp www-data'\e[0m and re-run the script."
    exit 1
fi

# Create the directory structure
echo -e "\e[38;5;72m[INFO]\e[0m Creating project directory structure..."
cmd="sudo"
[ "$environment" = "local" ] && cmd=""
$cmd mkdir -m 755 -p \
    "${project_path}/ssl" \
    "${project_path}/docker" \
    "${project_path}/log/nginx" \
    "${project_path}/conf/nginx/"{local,docker} \
    "${project_path}/conf/"{gunicorn,env_vars,redis} \
    "${project_path}/${project_name}/"{apps,templates,jinja2,requirements,staticfiles} \
    "${project_path}/${project_name}/static/"{css,js,images,admin} \
    "${project_path}/${project_name}/media/uploads"

# Set ownership for web server directories
if [ "$environment" = "local" ]; then
    chown -R "${USER}:www-data" "${project_path}"
else
    sudo chown -R www-data:www-data "${project_path}"
fi

# Determine command prefix based on environment
cmd="sudo"
[ "$environment" = "local" ] && cmd=""

# Set base permissions for directories
$cmd chmod -R 755 \
    "${project_path}/conf" \
    "${project_path}/ssl"
$cmd chmod -R 775 \
    "${project_path}/log" \
    "${project_path}/${project_name}/media"

# Handle environment-specific directory permissions
if [ "$environment" = "local" ]; then
    $cmd chmod -R 775 \
        "${project_path}/docker" \
        "${project_path}/${project_name}/"{requirements,staticfiles}
else
    $cmd chmod -R 755 \
        "${project_path}/docker" \
        "${project_path}/${project_name}/"{requirements,staticfiles}
fi

# Set specific permissions for files
$cmd find "${project_path}/conf" -type f -exec chmod 644 {} \;
$cmd find "${project_path}/ssl" -type f -exec chmod 600 {} \;

# Handle environment-specific file permissions
if [ "$environment" = "local" ]; then
    $cmd find "${project_path}/"{log,docker,${project_name}/requirements,${project_name}/media,${project_name}/staticfiles} -type f -exec chmod 664 {} \;
else
    $cmd find "${project_path}/"{log,${project_name}/media} -type f -exec chmod 664 {} \;
    $cmd find "${project_path}/"{docker,${project_name}/requirements,${project_name}/staticfiles} -type f -exec chmod 644 {} \;
fi

# Create requirements files
echo -e "\e[38;5;72m[INFO]\e[0m Creating requirements files..."
base_in_content=$(cat << EOL
# Main framework
Django>=5.0,<5.1                # https://www.djangoproject.com/

# Database
psycopg[c]>=3.2.6               # https://github.com/psycopg/psycopg (C bindings for performance)

# Configuration
django-environ>=0.12.0          # https://github.com/joke2k/django-environ

# HTTP requests
requests>=2.31.0                # https://github.com/psf/requests

# Deployment
gunicorn>=23.0.0                # https://github.com/benoitc/gunicorn

# Templating
jinja2>=3.1.2                   # https://github.com/pallets/jinja
django-jinja>=2.10.3            # https://github.com/niwinz/django-jinja

# Authentication
django-allauth[mfa]>=65.4.1     # https://github.com/pennersr/django-allauth (MFA support)
EOL
)
if [ "$environment" = "local" ]; then
    echo "$base_in_content" > "${project_path}/${project_name}/requirements/base.in"
else
    echo "$base_in_content" | sudo tee "${project_path}/${project_name}/requirements/base.in" > /dev/null
fi

local_in_content=$(cat << EOL
-r base.in

# Development tools
ipython>=8.14.0                 # https://github.com/ipython/ipython
django-debug-toolbar>=5.1.0     # https://github.com/jazzband/django-debug-toolbar
django-extensions>=3.2.3        # https://github.com/django-extensions/django-extensions

# Code quality
ruff>=0.11.2                    # https://github.com/astral-sh/ruff
coverage>=7.7.1                 # https://github.com/nedbat/coveragepy
pre-commit>=3.6.0               # https://github.com/pre-commit/pre-commit
mypy>=1.15.0                    # https://github.com/python/mypy
django-stubs>=5.1.3             # https://github.com/typeddjango/django-stubs
djlint>=1.34.1                  # https://github.com/Riverside-Healthcare/djlint

# Testing
pytest>=8.3.5                   # https://github.com/pytest-dev/pytest
pytest-django>=4.10.0           # https://github.com/pytest-dev/pytest-django
factory-boy>=3.3.2              # https://github.com/FactoryBoy/factory_boy
EOL
)
if [ "$environment" = "local" ]; then
    echo "$local_in_content" > "${project_path}/${project_name}/requirements/local.in"
else
    echo "$local_in_content" | sudo tee "${project_path}/${project_name}/requirements/local.in" > /dev/null
fi

production_in_content=$(cat << EOL
-r base.in

# Security
argon2-cffi>=23.1.0             # https://github.com/hynek/argon2_cffi (password hashing)

# Caching
redis>=5.0.0                    # https://github.com/redis/redis-py (Redis client)
django-redis>=5.4.0             # https://github.com/jazzband/django-redis (Redis caching)

# Performance
django-storages[s3]>=1.14.5     # https://github.com/jschneier/django-storages (S3 storage)
whitenoise>=6.8.0               # https://github.com/evansd/whitenoise (static files)

# Monitoring
sentry-sdk>=2.0.0               # https://github.com/getsentry/sentry-python (error tracking)
EOL
)
if [ "$environment" = "local" ]; then
    echo "$production_in_content" > "${project_path}/${project_name}/requirements/production.in"
else
    echo "$production_in_content" | sudo tee "${project_path}/${project_name}/requirements/production.in" > /dev/null
fi

# Create log files with proper permissions
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/access.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/error.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/django.log"
# Create Gunicorn log files based on environment
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/gunicorn-${environment}-access.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/gunicorn-${environment}-error.log"

# Create pyproject.toml for Ruff configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating pyproject.toml for Ruff configuration..."
pyproject_content=$(cat << EOL
[tool.ruff]
src = ["${project_name}"]
line-length = 88
target-version = "py312"
exclude = [
    "${project_name}/config/asgi.py",
    "${project_name}/config/wsgi.py",
    "${project_name}/manage.py",
    "${project_name}/**/migrations/*",
    "${project_name}/**/tests/*",
    "${project_name}/static/**/*",
    "**/__pycache__/",
    "**/*.pyc",
    "**/*.j2",
]

[tool.ruff.lint]
select = [
    "E", "F", "W", "I",
    "DJ", "UP", "RUF",
    "D", "C90", "N",
    "S", "B", "A",
    "C4",
    "DTZ",
    "T10", "PERF"
]
ignore = [
    "E501",
    "D100",
    "D104",
    "D212",
    "D203",
    "S101"
]
fixable = [
    "E", "F", "W", "I", "UP", "RUF", "C4", "T10"
]

[tool.ruff.lint.per-file-ignores]
"${project_name}/config/settings/local.py" = ["F403", "F405"]
"${project_name}/config/settings/production.py" = ["F403", "F405"]

[tool.ruff.lint.isort]
known-first-party = ["${project_name}"]

[tool.ruff.lint.pydocstyle]
convention = "google"

[tool.ruff.format]
quote-style = "single"
indent-style = "space"

[tool.pytest.ini_options]
minversion = "6.0"
addopts = "--ds=${project_name}.config.settings.test --import-mode=importlib"
python_files = ["tests.py", "test_*.py"]
DJANGO_SETTINGS_MODULE = "${project_name}.config.settings.test"

[tool.mypy]
python_version = "3.12"
check_untyped_defs = true
warn_unused_ignores = true
warn_redundant_casts = true
warn_unused_configs = true
plugins = ["mypy_django_plugin.main"]
disallow_untyped_defs = true

[tool.mypy.overrides]
module = [
    "${project_name}.*.migrations.*",
    "allauth.*"
]
ignore_errors = true

[tool.django-stubs]
django_settings_module = "${project_name}.config.settings"

[tool.ruff.lint.mccabe]
max-complexity = 12
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/pyproject.toml"
    echo "$pyproject_content" > "${project_path}/pyproject.toml"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/pyproject.toml"
    echo "$pyproject_content" | sudo tee "${project_path}/pyproject.toml" > /dev/null
fi

# Create .djlintrc for djlint configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating .djlintrc for djlint configuration..."
djlintrc_content=$(cat << EOL
{
    "profile": "jinja",
    "extension": "j2",
    "ignore": "static/,media/,migrations/",
    "indent": 2,
    "max_line_length": 88
}
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/.djlintrc"
    echo "$djlintrc_content" > "${project_path}/.djlintrc"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/.djlintrc"
    echo "$djlintrc_content" | sudo tee "${project_path}/.djlintrc" > /dev/null
fi

# Create .pre-commit-config.yaml for pre-commit hooks
echo -e "\e[38;5;72m[INFO]\e[0m Creating .pre-commit-config.yaml for pre-commit hooks..."
pre_commit_content=$(cat << EOL
exclude: '^${project_name}/static/.*|.*/migrations/.*|.*/__pycache__/.*'
default_stages: [pre-commit]
minimum_pre_commit_version: "3.2.0"
default_language_version:
  python: python3.12

repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-json
      - id: check-toml
      - id: check-yaml
      - id: debug-statements
      - id: detect-private-key

  - repo: https://github.com/pre-commit/mirrors-prettier
    rev: v4.0.0-alpha.8
    hooks:
      - id: prettier
        args: ['--tab-width', '2', '--single-quote']
        files: '${project_name}/jinja2/.*'

  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.4
    hooks:
      - id: ruff
        args: [--fix, --exit-non-zero-on-fix]
      - id: ruff-format
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/.pre-commit-config.yaml"
    echo "$pre_commit_content" > "${project_path}/.pre-commit-config.yaml"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/.pre-commit-config.yaml"
    echo "$pre_commit_content" | sudo tee "${project_path}/.pre-commit-config.yaml" > /dev/null
fi

# Create pytest.ini for pytest configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating pytest.ini for pytest configuration..."
pytest_ini_content=$(cat << EOL
[pytest]
DJANGO_SETTINGS_MODULE = config.settings.local
python_files = tests.py test_*.py
pythonpath = .
testpaths = ${project_name}/tests ${project_name}/apps
addopts =
    --strict-markers
    --tb=short
    --capture=no
    --cov=${project_name}/utils
    --cov=${project_name}/apps
    --cov-report=html
    --cov-report=term-missing
    --reuse-db
log_level = WARNING
markers =
    unit: Unit tests for individual components
    integration: Integration tests involving multiple components
    production: Tests that require production settings
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/pytest.ini"
    echo "$pytest_ini_content" > "${project_path}/pytest.ini"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/pytest.ini"
    echo "$pytest_ini_content" | sudo tee "${project_path}/pytest.ini" > /dev/null
fi

# Create .coveragerc for coverage configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating .coveragerc for coverage configuration..."
coveragerc_content=$(cat << EOL
[run]
# Only measure files under the "${project_name}" package
source = ${project_name}

# Exclude these patterns from the coverage measurement
omit =
    ${project_name}/*/tests/*
    ${project_name}/*/migrations/*
    ${project_name}/manage.py
    ${project_name}/config/wsgi.py
    ${project_name}/config/asgi.py
    ${project_name}/config/settings/*
    ${project_name}/jinja2/*
    ${project_name}/static/*
    ${project_name}/staticfiles/*
    ${project_name}/templates/*

# Measure branch coverage (which lines executed vs. logical branches)
branch = True

[report]
# Show which lines are missing
show_missing = True

# Do not count these lines (e.g. pragmas or __main__ guard)
exclude_lines =
    pragma: no cover
    if __name__ == '__main__':
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/.coveragerc"
    echo "$coveragerc_content" > "${project_path}/.coveragerc"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/.coveragerc"
    echo "$coveragerc_content" | sudo tee "${project_path}/.coveragerc" > /dev/null
fi

# Create Redis configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating Redis configuration file..."
sudo install -o www-data -g www-data -m 644 /dev/null "${project_path}/conf/redis/redis.conf"
sudo tee "${project_path}/conf/redis/redis.conf" > /dev/null << EOL
# Redis configuration file
# This is a basic configuration for development/testing.
# Adjust settings (e.g., maxmemory, requirepass) before production use.

# Listen on all interfaces
bind 0.0.0.0

# Default Redis port
port 6379

# Number of databases
databases 16

# Memory limit (adjust based on your needs)
maxmemory 256mb

# Eviction policy when memory is full
maxmemory-policy allkeys-lru

# Uncomment and set a password for production
# requirepass your_secure_password

# Log level: debug, verbose, notice, warning
loglevel notice

# Empty means logs go to stdout (Docker-friendly)
logfile ""
EOL

# Create Docker files
echo -e "\e[38;5;72m[INFO]\e[0m Creating Docker configuration files..."
docker_compose_content=$(cat << EOL
services:
  django:
    container_name: django
    build:
      context: .
      dockerfile: docker/Dockerfile.django
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
      - ./${project_name}/staticfiles:/app/staticfiles:ro
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
    volumes:
      - ./conf/redis/redis.conf:/usr/local/etc/redis/redis.conf
    command: redis-server /usr/local/etc/redis/redis.conf
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
)
if [ "$environment" = "local" ]; then
    install -m 664 /dev/null "${project_path}/docker-compose.yml"
    echo "$docker_compose_content" > "${project_path}/docker-compose.yml"
else
    sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/docker-compose.yml"
    echo "$docker_compose_content" | sudo tee "${project_path}/docker-compose.yml" > /dev/null
fi

dockerfile_django_content=$(cat << EOL
# Stage 1: Base build stage
FROM python:3.12-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \\
    libpq-dev \\
    gcc \\
    libc6-dev \\
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy the project directory
COPY ${project_name} /app/${project_name}/

# Install uv and dependencies using uv directly to system Python
RUN pip install --no-cache-dir uv && \\
    uv pip install --system --no-cache-dir -r /app/${project_name}/requirements/production.txt

# Stage 2: Production stage
FROM python:3.12-slim

# Set environment variables to optimize Python
ENV PYTHONDONTWRITEBYTECODE=1 \\
    PYTHONUNBUFFERED=1

# Install runtime dependencies for psycopg
RUN apt-get update && apt-get install -y --no-install-recommends \\
    libpq5 \\
    && rm -rf /var/lib/apt/lists/*

# Create /app directory and set ownership
RUN mkdir -p /app && chown -R www-data:www-data /app

# Set the working directory
WORKDIR /app

COPY --from=builder --chown=www-data:www-data \\
    /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=builder --chown=www-data:www-data \\
    /usr/local/bin/ /usr/local/bin/
COPY --from=builder --chown=www-data:www-data \\
    /app /app

# Copy entrypoint script
COPY --chown=www-data:www-data docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER www-data
ENTRYPOINT ["/entrypoint.sh"]
EOL
)
if [ "$environment" = "local" ]; then
    install -m 664 /dev/null "${project_path}/docker/Dockerfile.django"
    echo "$dockerfile_django_content" > "${project_path}/docker/Dockerfile.django"
else
    sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/docker/Dockerfile.django"
    echo "$dockerfile_django_content" | sudo tee "${project_path}/docker/Dockerfile.django" > /dev/null
fi

dockerfile_nginx_content=$(cat << EOL
FROM nginx:stable-alpine

# Copy the main nginx configuration file
COPY conf/nginx/docker/nginx.conf /etc/nginx/nginx.conf

# Copy the additional configuration file for virtual hosts
COPY conf/nginx/docker/${project_name}.conf /etc/nginx/conf.d/default.conf

# Copy SSL certificates
COPY ssl/cert.crt /etc/nginx/ssl/cert.crt
COPY ssl/cert.key /etc/nginx/ssl/cert.key

# Create SSL directory and set ownership and permissions
RUN mkdir -p /etc/nginx/ssl && \\
    chown -R nginx:nginx /etc/nginx/ssl && \\
    chmod 644 /etc/nginx/ssl/cert.crt && \\
    chmod 600 /etc/nginx/ssl/cert.key

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
)
if [ "$environment" = "local" ]; then
    install -m 664 /dev/null "${project_path}/docker/Dockerfile.nginx"
    echo "$dockerfile_nginx_content" > "${project_path}/docker/Dockerfile.nginx"
else
    sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/docker/Dockerfile.nginx"
    echo "$dockerfile_nginx_content" | sudo tee "${project_path}/docker/Dockerfile.nginx" > /dev/null
fi

entrypoint_content=$(cat << EOL
#!/bin/sh

echo "Applying database migrations..."
python3 ${project_name}/manage.py migrate --noinput || { echo "Migration failed"; exit 1; }

echo "Collecting static files..."
python3 ${project_name}/manage.py collectstatic --noinput || { echo "Collectstatic failed"; exit 1; }

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
)
if [ "$environment" = "local" ]; then
    install -m 755 /dev/null "${project_path}/docker/entrypoint.sh"
    echo "$entrypoint_content" > "${project_path}/docker/entrypoint.sh"
else
    sudo install -m 755 -o www-data -g www-data /dev/null "${project_path}/docker/entrypoint.sh"
    echo "$entrypoint_content" | sudo tee "${project_path}/docker/entrypoint.sh" > /dev/null
fi

# Configure environment variables
echo -e "\e[38;5;72m[INFO]\e[0m Configuring environment variables..."
sudo install -o www-data -g www-data -m 644 /dev/null "${project_path}/conf/env_vars/local.env"
cat << EOL | sudo tee "${project_path}/conf/env_vars/local.env" > /dev/null
DEBUG=True
SECRET_KEY=
ALLOWED_HOSTS=${project_domain},127.0.0.1
DJANGO_SETTINGS_MODULE=config.settings.local

# PostgreSQL settings
DATABASE_URL=postgres://${project_name}_user:${project_name}_password@localhost:5432/${project_name}_db
EOL

sudo install -o www-data -g www-data -m 644 /dev/null "${project_path}/conf/env_vars/production.env"
cat << EOL | sudo tee "${project_path}/conf/env_vars/production.env" > /dev/null
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
sudo -u postgres psql -q <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${project_name}_user') THEN
        CREATE ROLE ${project_name}_user
            WITH LOGIN
                 PASSWORD '${project_name}_password'
                 CREATEDB;
        RAISE NOTICE 'User % created with settings.', '${project_name}_user';
    ELSE
        RAISE NOTICE 'User % already exists. Skipping creation and settings.', '${project_name}_user';
    END IF;

    ALTER ROLE ${project_name}_user SET client_encoding TO 'utf8';
    ALTER ROLE ${project_name}_user SET default_transaction_isolation TO 'read committed';
    ALTER ROLE ${project_name}_user SET timezone TO 'UTC';
END
\$\$;
EOF
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create PostgreSQL user ${project_name}_user."
    exit 1
fi

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

sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE ${project_name}_db TO ${project_name}_user;"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to grant privileges on database ${project_name}_db."
    exit 1
fi

# Create .gitignore file
echo -e "\e[38;5;72m[INFO]\e[0m Creating .gitignore file..."
gitignore_content=$(cat << EOL
install.sh

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
ssl/

# Jinja2
jinja2/*.pyc
jinja2/__pycache__/
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/.gitignore"
    echo "$gitignore_content" > "${project_path}/.gitignore"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/.gitignore"
    echo "$gitignore_content" | sudo tee "${project_path}/.gitignore" > /dev/null
fi

# Create .dockerignore file
dockerignore_content=$(cat << EOL
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
!docker/Dockerfile.django
!docker/Dockerfile.nginx

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
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/.dockerignore"
    echo "$dockerignore_content" > "${project_path}/.dockerignore"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/.dockerignore"
    echo "$dockerignore_content" | sudo tee "${project_path}/.dockerignore" > /dev/null
fi

# Check if uv is installed, install it if not
if ! command -v uv &> /dev/null; then
    echo -e "\e[38;5;72m[INFO]\e[0m Installing uv..."
    python3 -m pip install uv
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install uv."
        exit 1
    fi
    if ! command -v uv &> /dev/null; then
        echo -e "\e[38;5;196m[ERROR]\e[0m uv installed but not found in PATH. Ensure PATH is configured correctly."
        exit 1
    fi
fi

# Determine the full path to uv
uv_path=$(which uv)
if [ -z "$uv_path" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Could not determine the path to uv. Please ensure it is installed and accessible."
    exit 1
fi

# Set up uv cache directory for production
if [ "$environment" = "production" ]; then
    uv_cache_path="${project_path}/.cache/uv"
    echo -e "\e[38;5;72m[INFO]\e[0m Setting up uv cache directory at $uv_cache_path..."
    sudo mkdir -m 755 -p "$uv_cache_path"
    sudo chown -R www-data:www-data "${project_path}/.cache"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create or set ownership for uv cache directory $uv_cache_path."
        exit 1
    fi
fi

# Set up Python virtual environment
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Python virtual environment with uv at $venv_path..."
if [ "$environment" = "local" ]; then
    "$uv_path" venv "$venv_path"
else
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$uv_path" venv "$venv_path"
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create virtual environment at $venv_path."
    exit 1
fi

# Verify virtual environment creation
if [ ! -f "$venv_path/bin/python3" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment at $venv_path is incomplete or corrupted."
    exit 1
fi

# Ensure pip is available and up-to-date in the virtual environment
if [ "$environment" = "local" ]; then
    "$venv_path/bin/python3" -m ensurepip --upgrade
    "$venv_path/bin/python3" -m pip install --upgrade pip
else
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$venv_path/bin/python3" -m ensurepip --upgrade
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$venv_path/bin/python3" -m pip install --upgrade pip
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to ensure pip in virtual environment at $venv_path."
    exit 1
fi

# Set ownership for production environment
if [ "$environment" = "production" ]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Setting ownership to www-data for production environment..."
    sudo chown -R www-data:www-data "${venv_path}"
    sudo chmod -R 755 "/opt/${project_name}App"
fi

# Compile requirements files
echo -e "\e[38;5;72m[INFO]\e[0m Compiling requirements files with uv..."
cd "${project_path}"  # Ensure we are in the project root directory
if [ ! -f "${project_path}/${project_name}/requirements/base.in" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Requirements file ${project_path}/${project_name}/requirements/base.in not found."
    exit 1
fi
if [ "$environment" = "local" ]; then
    "$uv_path" pip compile "${project_path}/${project_name}/requirements/base.in" --output-file "${project_path}/${project_name}/requirements/base.txt"
else
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$uv_path" pip compile "${project_path}/${project_name}/requirements/base.in" --output-file "${project_path}/${project_name}/requirements/base.txt"
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile base.txt requirements."
    exit 1
fi
if [ ! -f "${project_path}/${project_name}/requirements/local.in" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Requirements file ${project_path}/${project_name}/requirements/local.in not found."
    exit 1
fi
if [ "$environment" = "local" ]; then
    "$uv_path" pip compile "${project_path}/${project_name}/requirements/local.in" --output-file "${project_path}/${project_name}/requirements/local.txt"
else
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$uv_path" pip compile "${project_path}/${project_name}/requirements/local.in" --output-file "${project_path}/${project_name}/requirements/local.txt"
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile local.txt requirements."
    exit 1
fi
if [ ! -f "${project_path}/${project_name}/requirements/production.in" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Requirements file ${project_path}/${project_name}/requirements/production.in not found."
    exit 1
fi
if [ "$environment" = "local" ]; then
    "$uv_path" pip compile "${project_path}/${project_name}/requirements/production.in" --output-file "${project_path}/${project_name}/requirements/production.txt"
else
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$uv_path" pip compile "${project_path}/${project_name}/requirements/production.in" --output-file "${project_path}/${project_name}/requirements/production.txt"
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile production.txt requirements."
    exit 1
fi

# Install dependencies with uv based on environment
echo -e "\e[38;5;72m[INFO]\e[0m Installing ${environment} dependencies with uv..."
if [ "$environment" = "local" ]; then
    if [ ! -f "${project_path}/${project_name}/requirements/${environment}.txt" ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Requirements file ${project_path}/${project_name}/requirements/${environment}.txt not found."
        exit 1
    fi
    "$uv_path" pip install --python "$venv_path/bin/python3" -r "${project_path}/${project_name}/requirements/${environment}.txt"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install development dependencies."
        exit 1
    fi
else
    if [ ! -f "${project_path}/${project_name}/requirements/production.txt" ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Requirements file ${project_path}/${project_name}/requirements/production.txt not found."
        exit 1
    fi
    sudo -u www-data env uv_cache_path="${project_path}/.cache/uv" HOME="${project_path}" "$uv_path" pip install --python "$venv_path/bin/python3" -r "${project_path}/${project_name}/requirements/production.txt"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install production dependencies."
        exit 1
    fi
fi

# Create Django project
echo -e "\e[38;5;72m[INFO]\e[0m Creating Django project..."
if [ "$environment" = "local" ]; then
    if [ ! -f "$venv_path/bin/activate" ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at $venv_path/bin/activate."
        exit 1
    fi
    source "$venv_path/bin/activate"
    django-admin startproject config "${project_name}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create Django project in development environment."
        exit 1
    fi
    deactivate
else
    sudo -u www-data "$venv_path/bin/django-admin" startproject config "${project_path}/${project_name}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create Django project in production environment."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Setting ownership and permissions for project directory..."
    sudo chown -R www-data:www-data "${project_path}/${project_name}"
    sudo chmod -R 755 "${project_path}/${project_name}"
    sudo find "${project_path}/${project_name}" -type f -exec chmod 644 {} \;
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to set ownership or permissions for project directory."
        exit 1
    fi
fi
cd "${project_path}/${project_name}"

# Create applications directory
echo -e "\e[38;5;72m[INFO]\e[0m Setting up applications directory..."
if [ "$environment" = "local" ]; then
    touch "${project_path}/${project_name}/apps/__init__.py"
else
    sudo -u www-data touch "${project_path}/${project_name}/apps/__init__.py"
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create ${project_path}/${project_name}/apps/__init__.py."
    exit 1
fi

# Create settings directory and split settings files
echo -e "\e[38;5;72m[INFO]\e[0m Creating settings directory and split settings files..."
if [ "$environment" = "local" ]; then
    mkdir -m 755 -p config/settings
else
    sudo -u www-data mkdir -m 755 -p config/settings
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create config/settings directory."
    exit 1
fi
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null config/settings/__init__.py
    install -m 644 /dev/null config/settings/base.py
    install -m 644 /dev/null config/settings/local.py
    install -m 644 /dev/null config/settings/production.py
    install -m 644 /dev/null config/settings/test.py
else
    sudo -u www-data install -m 644 /dev/null config/settings/__init__.py
    sudo -u www-data install -m 644 /dev/null config/settings/base.py
    sudo -u www-data install -m 644 /dev/null config/settings/local.py
    sudo -u www-data install -m 644 /dev/null config/settings/production.py
    sudo -u www-data install -m 644 /dev/null config/settings/test.py
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create settings files."
    exit 1
fi

# Populate settings/base.py
base_settings_content=$(cat << EOL
import sys
from pathlib import Path

import environ
from django.utils.translation import gettext_lazy as _

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
    'allauth',
    'allauth.account',
    'allauth.socialaccount',
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
    'allauth.account.middleware.AccountMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

# URL configuration
ROOT_URLCONF = 'config.urls'

# WSGI application
WSGI_APPLICATION = 'config.wsgi.application'

# Template engines - Jinja2 and Django templates configuration
TEMPLATES = [
    {
        'BACKEND': 'django_jinja.backend.Jinja2',
        'DIRS': [BASE_DIR / '${project_name}/jinja2'],
        'APP_DIRS': True,
        'OPTIONS': {
            'match_extension': '.j2',
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
                'django.template.context_processors.csrf',
            ],
            'extensions': [
                'django_jinja.builtins.extensions.DjangoFiltersExtension',
                'django_jinja.builtins.extensions.CsrfExtension',  # For proper csrf_token work
                'django_jinja.builtins.extensions.StaticFilesExtension',  # For static
                'django_jinja.builtins.extensions.UrlsExtension',  # For url
                'django_jinja.builtins.extensions.TimezoneExtension',  # For timezone support
                'django_jinja.builtins.extensions.DjangoExtraFiltersExtension',  # Additional Django filters
                'jinja2.ext.i18n',  # For internationalization
                'jinja2.ext.loopcontrols',  # For break/continue in loops
            ],
            'trim_blocks': True,  # Removes first empty line after a block
            'lstrip_blocks': True,  # Removes spaces and tabs at the beginning of a line before a block
            'auto_reload': env.bool('DEBUG', default=True),  # Automatic template reloading during debugging mode
            'newstyle_gettext': True,  # New style gettext for internationalization
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

# Authentication backends for django-allauth
AUTHENTICATION_BACKENDS = [
    'django.contrib.auth.backends.ModelBackend',
    'allauth.account.auth_backends.AuthenticationBackend',
]

# Password validation - Rules for secure passwords
AUTH_PASSWORD_VALIDATORS = [
    {
        'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    },
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
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

# Security settings - Basic protections against common vulnerabilities
SESSION_COOKIE_HTTPONLY = True
CSRF_COOKIE_HTTPONLY = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'

# Admin - Contact information for error notifications
STAFF_ALEXEY = ('Alexey', 'aleksey.sundyrev@gmail.com')
ADMINS = STAFF_ALEXEY
MANAGERS = ADMINS

# Sites framework - Default site ID for django.contrib.sites
SITE_ID = 1

# Default primary key field type - For database models
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/${project_name}/config/settings/base.py"
    echo "$base_settings_content" > "${project_path}/${project_name}/config/settings/base.py"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/${project_name}/config/settings/base.py"
    echo "$base_settings_content" | sudo tee "${project_path}/${project_name}/config/settings/base.py" > /dev/null
fi

# Populate settings/local.py
local_settings_content=$(cat << EOL
from .base import *

env = environ.Env()

env.read_env(env_file=BASE_DIR / 'conf/env_vars/local.env')

# Basic settings
SECRET_KEY = env('SECRET_KEY')
DEBUG = True
ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=['localhost', '127.0.0.1'])

# Database - Configuration for local development
DATABASES = {
    'default': env.db('DATABASE_URL', default='postgres:///testapp'),
}
DATABASES['default']['ATOMIC_REQUESTS'] = True

# Development tools - Debugging and extension utilities
INSTALLED_APPS += [
    'debug_toolbar',
    'django_extensions',
]

MIDDLEWARE += [
    'debug_toolbar.middleware.DebugToolbarMiddleware',
]

INTERNAL_IPS = ['127.0.0.1']

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
            'level': 'INFO',
            'class': 'logging.FileHandler',
            'filename': BASE_DIR / 'log/django.log',
            'formatter': 'verbose',
        },
    },
    'root': {
        'handlers': ['console', 'file'],
        'level': 'INFO',
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
        'faker': {
            'handlers': ['console'],
            'level': 'WARNING',
            'propagate': False,
        },
        'django.server': {
            'handlers': ['console'],
            'level': 'INFO',
            'propagate': False,
        },
    },
}
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/${project_name}/config/settings/local.py"
    echo "$local_settings_content" > "${project_path}/${project_name}/config/settings/local.py"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/${project_name}/config/settings/local.py"
    echo "$local_settings_content" | sudo tee "${project_path}/${project_name}/config/settings/local.py" > /dev/null
fi

# Populate settings/production.py
production_settings_content=$(cat << EOL
from .base import *

env = environ.Env()

env.read_env(env_file=BASE_DIR / 'conf/env_vars/production.env')

# Basic settings
SECRET_KEY = env('SECRET_KEY')
DEBUG = False
ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=['${project_domain}'])

# Database - Configuration for production with persistent connections
DATABASES = {
    'default': env.db('DATABASE_URL'),
}
DATABASES['default']['ATOMIC_REQUESTS'] = True
DATABASES['default']['CONN_MAX_AGE'] = env.int('CONN_MAX_AGE', default=60)

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
    },
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

# Static files - Storage configuration for production
STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/${project_name}/config/settings/production.py"
    echo "$production_settings_content" > "${project_path}/${project_name}/config/settings/production.py"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/${project_name}/config/settings/production.py"
    echo "$production_settings_content" | sudo tee "${project_path}/${project_name}/config/settings/production.py" > /dev/null
fi

# Populate settings/test.py
test_settings_content=$(cat << EOL
import environ

from .base import CACHES

env = environ.Env()

# Basic settings
SECRET_KEY = env('SECRET_KEY')

# Test runner
TEST_RUNNER = 'django.test.runner.DiscoverRunner'

# Password hashers - Optimized for testing
PASSWORD_HASHERS = ['django.contrib.auth.hashers.MD5PasswordHasher']

# Email settings - In-memory backend for testing
EMAIL_BACKEND = 'django.core.mail.backends.locmem.EmailBackend'

# Caching - Use LocMemCache for testing
CACHES = {
    'default': CACHES['localmem'],  # Use LocMemCache from base.py for testing
}
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${project_path}/${project_name}/config/settings/test.py"
    echo "$test_settings_content" > "${project_path}/${project_name}/config/settings/test.py"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${project_path}/${project_name}/config/settings/test.py"
    echo "$test_settings_content" | sudo tee "${project_path}/${project_name}/config/settings/test.py" > /dev/null
fi

# Remove the original settings.py
echo -e "\e[38;5;72m[INFO]\e[0m Removing original settings.py..."
if [ -f "${project_path}/${project_name}/config/settings.py" ]; then
    if [ "$environment" = "local" ]; then
        rm -f "${project_path}/${project_name}/config/settings.py"
    else
        sudo rm -f "${project_path}/${project_name}/config/settings.py"
    fi
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to remove original settings.py."
        exit 1
    fi
else
    echo -e "\e[38;5;208m[WARNING]\e[0m Original settings.py not found, skipping removal."
fi

# Generate a secure SECRET_KEY and update .env files
echo -e "\e[38;5;72m[INFO]\e[0m Generating a secure SECRET_KEY and updating .env files..."
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
SECRET_KEY_ESCAPED=$(echo "$SECRET_KEY" | sed 's/[&/\]/\\&/g')
sudo sed -i "s/^SECRET_KEY=.*/SECRET_KEY='${SECRET_KEY_ESCAPED}'/" "${project_path}/conf/env_vars/local.env"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update SECRET_KEY in local.env."
    exit 1
fi
sudo sed -i "s/^SECRET_KEY=.*/SECRET_KEY='${SECRET_KEY_ESCAPED}'/" "${project_path}/conf/env_vars/production.env"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update SECRET_KEY in production.env."
    exit 1
fi

# Update settings/urls.py
echo -e "\e[38;5;72m[INFO]\e[0m Updating urls.py..."
urls_path="${project_path}/${project_name}/config/urls.py"
urls_content=$(cat << EOL
from django.conf import settings
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path('admin/', admin.site.urls),
]

if settings.DEBUG:
    urlpatterns.append(path('__debug__/', include('debug_toolbar.urls')))
EOL
)
if [ "$environment" = "local" ]; then
    install -m 644 /dev/null "${urls_path}"
    echo "$urls_content" > "${urls_path}"
else
    sudo install -m 644 -o www-data -g www-data /dev/null "${urls_path}"
    echo "$urls_content" | sudo tee "${urls_path}" > /dev/null
fi
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update urls.py."
    exit 1
fi

# Load environment variables before collecting static files
echo -e "\e[38;5;72m[INFO]\e[0m Loading environment variables from ${environment}.env..."
export $(grep -v '^#' "${project_path}/conf/env_vars/${environment}.env" | xargs)
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to export environment variables from ${environment}.env."
    exit 1
fi

# Collect static files
if [ "$environment" = "local" ]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Collecting static files..."
    if [ ! -f "$venv_path/bin/activate" ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at $venv_path/bin/activate."
        exit 1
    fi
    source "$venv_path/bin/activate"
    export DJANGO_SETTINGS_MODULE=config.settings.local
    python3 "${project_path}/${project_name}/manage.py" collectstatic --noinput
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to collect static files."
        deactivate
        exit 1
    fi
    deactivate
    echo -e "\e[38;5;72m[INFO]\e[0m Setting correct ownership for static files..."
    sudo chown -R "${USER}:www-data" "${project_path}/${project_name}/staticfiles"
    chmod -R 775 "${project_path}/${project_name}/staticfiles"
    find "${project_path}/${project_name}/staticfiles" -type f -exec chmod 664 {} \;
else
    echo -e "\e[38;5;72m[INFO]\e[0m Collecting static files for production..."
    if [ ! -f "$venv_path/bin/activate" ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at $venv_path/bin/activate."
        exit 1
    fi
    sudo -u www-data env DJANGO_SETTINGS_MODULE=config.settings.production "$venv_path/bin/python3" "${project_path}/${project_name}/manage.py" collectstatic --noinput
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to collect static files in production."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Setting correct ownership for static files..."
    sudo chown -R www-data:www-data "${project_path}/${project_name}/staticfiles"
    sudo chmod -R 755 "${project_path}/${project_name}/staticfiles"
    sudo find "${project_path}/${project_name}/staticfiles" -type f -exec chmod 644 {} \;
fi

# Configure Gunicorn template units
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Gunicorn template units..."
gunicorn_socket="${project_path}/conf/gunicorn/${project_name}.gunicorn@.socket"
gunicorn_service="${project_path}/conf/gunicorn/${project_name}.gunicorn@.service"

cat <<EOF | sudo tee "${gunicorn_socket}" > /dev/null
[Unit]
Description=Gunicorn socket for ${project_name} (%i)
After=network.target

[Socket]
ListenStream=/run/${project_name}.gunicorn.sock
SocketUser=www-data
SocketGroup=www-data
SocketMode=0660
Service=${project_name}.gunicorn@%i.service

[Install]
WantedBy=sockets.target
EOF
sudo chmod 644 "${gunicorn_socket}"

cat <<EOF | sudo tee "${gunicorn_service}" > /dev/null
[Unit]
Description=Gunicorn daemon for ${project_name} (%i)
After=network.target
Requires=${project_name}.gunicorn@%i.socket

[Service]
UMask=002
User=www-data
Group=www-data
WorkingDirectory=${project_path}/${project_name}
EnvironmentFile=${project_path}/conf/env_vars/%i.env
ExecStart=${venv_path}/bin/gunicorn \\
    --access-logfile ${project_path}/log/gunicorn-%i-access.log \\
    --error-logfile ${project_path}/log/gunicorn-%i-error.log \\
    --capture-output \\
    --workers 3 \\
    --bind unix:/run/${project_name}.gunicorn.sock \\
    config.wsgi:application
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo chmod 644 "${gunicorn_service}"

# Create symlinks for template units
sudo ln -s "${gunicorn_service}" "/etc/systemd/system/${project_name}.gunicorn@.service"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create symlink for Gunicorn template service."
    exit 1
fi
sudo ln -s "${gunicorn_socket}" "/etc/systemd/system/${project_name}.gunicorn@.socket"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create symlink for Gunicorn template socket."
    exit 1
fi

# Reload systemd to recognize new units
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload systemd daemon."
    exit 1
fi

# Configure Nginx configuration for Docker
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Nginx configuration..."
docker_nginx_conf="${project_path}/conf/nginx/docker/nginx.conf"
cat <<EOF | sudo tee "${docker_nginx_conf}" > /dev/null
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
sudo chmod 644 "${docker_nginx_conf}"

docker_project_conf="${project_path}/conf/nginx/docker/${project_name}.conf"
cat <<EOF | sudo tee "${docker_project_conf}" > /dev/null
server {
    listen 80;
    server_name ${project_domain};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name ${project_domain};

    ssl_certificate /etc/nginx/ssl/cert.crt;
    ssl_certificate_key /etc/nginx/ssl/cert.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

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
sudo chmod 644 "${docker_project_conf}"

local_nginx_conf="${project_path}/conf/nginx/local/nginx.conf"
cat <<EOF | sudo tee "${local_nginx_conf}" > /dev/null
user www-data;
worker_processes auto;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

pid /run/nginx.pid;

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
sudo chmod 644 "${local_nginx_conf}"
sudo install -m 644 "${local_nginx_conf}" /etc/nginx/nginx.conf
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install Nginx configuration."
    exit 1
fi

local_project_conf="${project_path}/conf/nginx/local/${project_name}.conf"
cat <<EOF | sudo tee "${local_project_conf}" > /dev/null
server {
    listen 80;
    server_name ${project_domain};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name ${project_domain};

    ssl_certificate /etc/nginx/ssl/cert.crt;
    ssl_certificate_key /etc/nginx/ssl/cert.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

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
sudo chmod 644 "${local_project_conf}"
sudo install -m 644 "${local_project_conf}" /etc/nginx/sites-available/${project_name}.conf
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install project-specific Nginx configuration for ${project_name}."
    exit 1
fi

sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload systemd daemon for Nginx."
    exit 1
fi

if [[ ! -f "/etc/nginx/sites-enabled/${project_name}.conf" ]]; then
    sudo ln -sf "${local_project_conf}" "/etc/nginx/sites-enabled/${project_name}.conf"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create symbolic link for Nginx configuration."
        exit 1
    fi
fi

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

# Initialize Git repository and install pre-commit hooks if environment is local
cd "${project_path}"
if [ "$environment" = "local" ]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Initializing Git repository..."
    git init
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to initialize Git repository."
        exit 1
    fi
    git add .gitignore .dockerignore .pre-commit-config.yaml .djlintrc pyproject.toml docker-compose.yml .coveragerc pytest.ini docker/ "${project_name}/"
    git commit -m "chore: init project structure"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create initial Git commit."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Installing pre-commit hooks..."
    if [ ! -f "$venv_path/bin/activate" ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at $venv_path/bin/activate."
        exit 1
    fi
    source "$venv_path/bin/activate"
    pre-commit install
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install pre-commit hooks."
        deactivate
        exit 1
    fi
    deactivate
fi

# Success message and script removal
echo -e "\e[38;5;48m[SUCCESS]\e[0m Django project initialized, keep up the good work!"
script_path="${project_path}/install.sh"
rm -f "$script_path"
if [ -f "$script_path" ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to remove install.sh at $script_path."
    exit 1
fi