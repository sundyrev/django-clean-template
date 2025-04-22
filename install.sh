#!/bin/bash
set -e

# Check if pyenv is installed
if ! command -v pyenv &> /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m pyenv is not installed. Please install it before proceeding."
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
            echo -e "\e[38;5;196m[ERROR]\e[0m Invalid choice. Please enter \e[38;5;117m1\e[0m or \e[38;5;117m2\e[0m."
            ;;
    esac
done

# Set virtual environment path based on environment
if [ "$environment" = "local" ]; then
    venv_path="${project_path}/env"
else
    venv_path="/opt/${project_name}/env"
    sudo mkdir -p "/opt/${project_name}"
    sudo chown www-data:www-data "/opt/${project_name}"
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
# This is useful for ensuring proper permissions for web server-related tasks
if ! groups "${USER}" | grep -qw 'www-data'; then
    echo -e "\e[38;5;208m[WARNING]\e[0m User ${USER} is not in the www-data group. Adding user..."
    sudo usermod -aG www-data "${USER}"
    echo -e "\e[38;5;196m[ERROR]\e[0m Please restart your session or run \e[38;5;223m'newgrp www-data'\e[0m and re-run the script."
    exit 1
fi

# Create the directory structure
echo -e "\e[38;5;72m[INFO]\e[0m Creating project directory structure..."
mkdir -m 755 -p \
    "${project_path}/docker" \
    "${project_path}/log/nginx" \
    "${project_path}/conf/nginx/"{local,docker} \
    "${project_path}/conf/"{gunicorn,env_vars,redis} \
    "${project_path}/${project_name}/"{apps,templates,jinja2,requirements,staticfiles} \
    "${project_path}/${project_name}/static/"{css,js,images,admin} \
    "${project_path}/${project_name}/media/uploads"

# Set ownership for web server directories
sudo chown -R www-data:www-data \
    "${project_path}/log" \
    "${project_path}/conf" \
    "${project_path}/${project_name}/staticfiles" \
    "${project_path}/${project_name}/media"

# Set base permissions
sudo chmod -R 755 "${project_path}/conf"
sudo chmod -R 775 "${project_path}/log"
sudo chmod -R 755 "${project_path}/${project_name}/staticfiles"
sudo chmod -R 775 "${project_path}/${project_name}/media"

# Set specific permissions
sudo find "${project_path}/conf" -type f -exec chmod 644 {} \;
sudo find "${project_path}/log" -type f -exec chmod 664 {} \;
sudo find "${project_path}/${project_name}/staticfiles" -type f -exec chmod 644 {} \;
sudo find "${project_path}/${project_name}/media" -type f -exec chmod 664 {} \;

# Create requirements directory and base files
echo -e "\e[38;5;72m[INFO]\e[0m Creating requirements files..."
cat > "${project_path}/${project_name}/requirements/base.in" << EOL
# Main framework
Django>=5.0,<5.1                # https://www.djangoproject.com/

# Database
psycopg[c]>=3.2.6               # https://github.com/psycopg/psycopg (C bindings for performance)

# Configuration
django-environ>=0.12.0          # https://github.com/joke2k/django-environ

# Deployment
gunicorn>=23.0.0                # https://github.com/benoitc/gunicorn

# Templating
jinja2>=3.1.2                   # https://github.com/pallets/jinja

# Authentication & Security
django-allauth[mfa]>=65.4.1     # https://github.com/pennersr/django-allauth (MFA support)
django-recaptcha==4.1.0         # https://github.com/torchbox/django-recaptcha
EOL

cat > "${project_path}/${project_name}/requirements/local.in" << EOL
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

cat > "${project_path}/${project_name}/requirements/production.in" << EOL
-r base.in

# Security
argon2-cffi>=23.1.0             # https://github.com/hynek/argon2_cffi (password hashing)

# Caching
django-redis>=5.4.0             # https://github.com/jazzband/django-redis (Redis caching)

# Performance
django-storages[s3]>=1.14.5     # https://github.com/jschneier/django-storages (S3 storage)
whitenoise>=6.8.0               # https://github.com/evansd/whitenoise (static files)

# Monitoring
sentry-sdk>=2.0.0               # https://github.com/getsentry/sentry-python (error tracking)
EOL

# Create log files with proper permissions
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/access.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx/error.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/gunicorn.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/django.log"

# Create pyproject.toml for Ruff configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating pyproject.toml for Ruff configuration..."
install -m 644 /dev/null "${project_path}/pyproject.toml"
cat > "${project_path}/pyproject.toml" << EOL
[tool.ruff]
src = ["${project_name}"]                   # Project root directory
line-length = 88                            # Maximum line length
target-version = "py312"                    # Target Python version
exclude = [
    "${project_name}/config/asgi.py",       # Exclude ASGI configuration
    "${project_name}/config/wsgi.py",       # Exclude WSGI configuration
    "${project_name}/manage.py",            # Exclude manage.py
    "${project_name}/**/migrations/*",      # Exclude migrations
    "${project_name}/**/tests/*",           # Exclude tests
    "${project_name}/static/**/*",          # Exclude static files
    "**/__pycache__/",                      # Exclude Python cache
    "**/*.pyc",                             # Exclude compiled Python files
    "**/*.j2",                              # Exclude Jinja2 templates
]

[tool.ruff.lint]
select = [
    "E", "F", "W", "I",                     # PEP 8, Pyflakes, isort
    "DJ", "UP", "RUF",                      # Django, pyupgrade, Ruff-specific
    "D", "C90", "N",                        # Docstring, complexity, PEP 8 naming
    "S", "B", "A",                          # Security, bugbear, builtins
    "C4",                                   # Comprehensions
    "DTZ",                                  # Datetime
    "T10", "PERF"                           # Debug calls, performance
]
ignore = [
    "E501",                                 # Line too long
    "D100",                                 # Missing module docstring
    "D104",                                 # Missing package docstring
    "D212",                                 # Conflicts with D211
    "D203",                                 # Conflicts with D211
    "S101"                                  # Assert usage
]
fixable = [
    "E", "F", "W", "I", "UP", "RUF", "C4", "T10"  # Rules that Ruff can auto-fix
]

[tool.ruff.lint.per-file-ignores]
"${project_name}/config/settings/local.py" = ["F403", "F405"]       # Ignore * imports
"${project_name}/config/settings/production.py" = ["F403", "F405"]  # Ignore * imports

[tool.ruff.lint.isort]
known-first-party = ["${project_name}"]  # Custom modules

[tool.ruff.lint.pydocstyle]
convention = "google"                       # Docstring style

[tool.ruff.format]
quote-style = "single"                      # Single quotes
indent-style = "space"                      # Space indentation

[tool.pytest.ini_options]
minversion = "6.0"
addopts = "--ds=${project_name}.config.settings.test --import-mode=importlib"
python_files = ["tests.py", "test_*.py"]
DJANGO_SETTINGS_MODULE = "${project_name}.config.settings.test"  # Test settings

[tool.mypy]
python_version = "3.12"
check_untyped_defs = true
warn_unused_ignores = true
warn_redundant_casts = true
warn_unused_configs = true
plugins = ["mypy_django_plugin.main"]
disallow_untyped_defs = true  # Strict type checking

[tool.mypy.overrides]
module = [
    "${project_name}.*.migrations.*",       # Ignore migrations
    "allauth.*"                             # Ignore django-allauth
]
ignore_errors = true

[tool.django-stubs]
django_settings_module = "${project_name}.config.settings"  # Settings for django-stubs

[tool.ruff.lint.mccabe]
max-complexity = 12                         # Cyclomatic complexity limit
EOL

# Create .djlintrc for djlint configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating .djlintrc for djlint configuration..."
install -m 644 /dev/null "${project_path}/.djlintrc"
cat > "${project_path}/.djlintrc" << EOL
{
    "profile": "jinja",
    "extension": "j2",
    "ignore": "static/,media/,migrations/",
    "indent": 2,
    "max_line_length": 88
}
EOL

# Create .pre-commit-config.yaml for pre-commit hooks
echo -e "\e[38;5;72m[INFO]\e[0m Creating .pre-commit-config.yaml for pre-commit hooks..."
install -m 644 /dev/null "${project_path}/.pre-commit-config.yaml"
cat > "${project_path}/.pre-commit-config.yaml" << EOL
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

# Create pytest.ini for pytest configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating pytest.ini for pytest configuration..."
install -m 644 /dev/null "${project_path}/pytest.ini"
cat > "${project_path}/pytest.ini" << EOL
[pytest]
DJANGO_SETTINGS_MODULE = config.settings.local
python_files = tests.py test_*.py
addopts = --strict-markers --tb=short --capture=no
log_level = WARNING
EOL

# Create .coveragerc for coverage configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating .coveragerc for coverage configuration..."
install -m 644 /dev/null "${project_path}/.coveragerc"
cat > "${project_path}/.coveragerc" << EOL
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

# Create Redis configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating Redis configuration file..."
sudo install -o www-data -g www-data -m 644 /dev/null "${project_path}/conf/redis/redis.conf"
cat << EOL | sudo tee "${project_path}/conf/redis/redis.conf" > /dev/null
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
install -m 664 /dev/null "${project_path}/docker-compose.yml"
cat > "${project_path}/docker-compose.yml" << EOL
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

install -m 664 /dev/null "${project_path}/docker/Dockerfile.django"
cat > "${project_path}/docker/Dockerfile.django" << EOL
# Stage 1: Base build stage
FROM python:3.12-slim AS builder

# Install build dependencies for psycopg[c] and uv
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

# Copy installed dependencies and binaries from builder
COPY --from=builder /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /app /app

# Copy entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Switch to www-data user
USER www-data

# Start the application using Gunicorn
ENTRYPOINT ["/entrypoint.sh"]
EOL

install -m 664 /dev/null "${project_path}/docker/Dockerfile.nginx"
cat > "${project_path}/docker/Dockerfile.nginx" << EOL
FROM nginx:stable-alpine

# Copy the main nginx configuration file
COPY conf/nginx/docker/nginx.conf /etc/nginx/nginx.conf

# Copy the additional configuration file for virtual hosts
COPY conf/nginx/docker/${project_name}.conf /etc/nginx/conf.d/default.conf

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
python ${project_name}/manage.py migrate --noinput || { echo "Migration failed"; exit 1; }

echo "Collecting static files..."
python ${project_name}/manage.py collectstatic --noinput || { echo "Collectstatic failed"; exit 1; }

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
sudo install -o www-data -g www-data -m 644 /dev/null "${project_path}/conf/env_vars/local.env"
cat << EOL | sudo tee "${project_path}/conf/env_vars/local.env" > /dev/null
DEBUG=True
SECRET_KEY=
ALLOWED_HOSTS=${project_domain},127.0.0.1
DJANGO_SETTINGS_MODULE=config.settings.local

# PostgreSQL settings
DATABASE_URL=postgres://${project_name}_user:${project_name}_password@localhost:5432/${project_name}_db
EOL

 # Create production environment file with proper permissions
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
# Create user using PL/pgSQL
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
echo -e "\e[38;5;72m[INFO]\e[0m Creating .gitignore file..."
install -m 644 /dev/null "${project_path}/.gitignore"
cat > "${project_path}/.gitignore" << EOL
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

# Check if uv is installed, install it if not
if ! command -v uv &> /dev/null; then
    echo -e "\e[38;5;72m[INFO]\e[0m Installing uv..."
    python3 -m pip install uv
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install uv."
        exit 1
    fi
    # Rehash pyenv to update PATH
    pyenv rehash
    if ! command -v uv &> /dev/null; then
        echo -e "\e[38;5;196m[ERROR]\e[0m uv installed but not found in PATH. Ensure pyenv is configured correctly."
        exit 1
    fi
fi

# Set up Python virtual environment
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Python virtual environment at $venv_path..."
if [ "$environment" = "local" ]; then
    uv venv "$venv_path"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create development virtual environment."
        exit 1
    fi
else
    sudo -u www-data uv venv "$venv_path"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create production virtual environment."
        exit 1
    fi
fi

# Add DJANGO_SETTINGS_MODULE to the virtual environment's activate script (for development)
if [ "$environment" = "local" ]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Adding DJANGO_SETTINGS_MODULE to activate script..."
    echo "export DJANGO_SETTINGS_MODULE=config.settings.${environment}" >> "${venv_path}/bin/activate"
fi

# Upgrade pip in the virtual environment
echo -e "\e[38;5;72m[INFO]\e[0m Upgrading pip..."
if [ "$environment" = "local" ]; then
    source "$venv_path/bin/activate"
    pip install --upgrade pip
    deactivate
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to upgrade pip in development environment."
        exit 1
    fi
else
    sudo -u www-data "$venv_path/bin/pip" install --upgrade pip
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to upgrade pip in production environment."
        exit 1
    fi
fi

# Compile requirements files (using system uv)
echo -e "\e[38;5;72m[INFO]\e[0m Compiling requirements files..."
uv pip compile ${project_name}/requirements/base.in --output-file ${project_name}/requirements/base.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile base.txt requirements."
    exit 1
fi
uv pip compile ${project_name}/requirements/local.in --output-file ${project_name}/requirements/local.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile local.txt requirements."
    exit 1
fi
uv pip compile ${project_name}/requirements/production.in --output-file ${project_name}/requirements/production.txt
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to compile production.txt requirements."
    exit 1
fi

# Install dependencies based on environment
echo -e "\e[38;5;72m[INFO]\e[0m Installing ${environment} dependencies..."
if [ "$environment" = "local" ]; then
    source "$venv_path/bin/activate"
    uv pip sync "${project_path}/${project_name}/requirements/${environment}.txt"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install development dependencies."
        exit 1
    fi
    deactivate
else
    sudo -u www-data uv pip install --python "$venv_path/bin/python" -r "${project_path}/${project_name}/requirements/production.txt"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install production dependencies."
        exit 1
    fi
fi

# Create Django project
echo -e "\e[38;5;72m[INFO]\e[0m Creating Django project..."
if [ "$environment" = "local" ]; then
    source "$venv_path/bin/activate"
    django-admin startproject config "${project_name}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create Django project in development environment."
        exit 1
    fi
    deactivate
else
    # Run django-admin directly as www-data to set correct ownership, using the virtualenv's binary
    sudo -u www-data "$venv_path/bin/django-admin" startproject config "${project_path}/${project_name}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create Django project in production environment."
        exit 1
    fi
    # Set ownership for project directory in production
    echo -e "\e[38;5;72m[INFO]\e[0m Setting ownership for project directory to www-data..."
    sudo chown -R www-data:www-data "${project_path}/${project_name}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to set ownership for project directory."
        exit 1
    fi
fi
cd "${project_path}/${project_name}"

# Create applications directory
echo -e "\e[38;5;72m[INFO]\e[0m Setting up applications directory..."
touch "${project_path}/${project_name}/apps/__init__.py"

# Create Jinja2 environment configuration
echo -e "\e[38;5;72m[INFO]\e[0m Creating Jinja2 environment configuration..."
cat <<EOF > "${project_path}/${project_name}/config/jinja2.py"
from django.template.context_processors import csrf
from django.templatetags.static import static
from django.urls import reverse

from jinja2 import Environment, select_autoescape


def environment(**options):
    """Configure and return a Jinja2 environment."""
    options.pop('autoescape', None)
    env = Environment(
        autoescape=select_autoescape(
            enabled_extensions=('html', 'j2'),
            default_for_string=True,
        ),
        **options,
    )

    env.globals.update(
        {
            'static': static,
            'url': reverse,
            'csrf_token': csrf,
        }
    )

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
cat > "${project_path}/${project_name}/config/settings/base.py" << EOF
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
    {
        'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator',
    },
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
ADMINS = STAFF_ALEXEY
MANAGERS = ADMINS

# Sites framework - Default site ID for django.contrib.sites
SITE_ID = 1

# Authentication backends for django-allauth
AUTHENTICATION_BACKENDS = [
    'django.contrib.auth.backends.ModelBackend',
    'allauth.account.auth_backends.AuthenticationBackend',
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
EOF

# Populate settings/local.py
cat > "${project_path}/${project_name}/config/settings/local.py" << EOF
from .base import *

env = environ.Env()

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
EOF

# Populate settings/production.py
cat > "${project_path}/${project_name}/config/settings/production.py" << EOF
from .base import *

env = environ.Env()

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

# Static files - Storage configuration for production
STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'
EOF

# Populate settings/test.py
cat > "${project_path}/${project_name}/config/settings/test.py" << EOF
import environ

from .base import CACHES

env = environ.Env()

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
if [ -f "${project_path}/${project_name}/config/settings.py" ]; then
    rm -f "${project_path}/${project_name}/config/settings.py"
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
urls_path=config/urls.py
# Clearing the existing file
> "${urls_path}"
cat >> "${urls_path}" << 'EOF'
from django.conf import settings
from django.contrib import admin
from django.urls import include, path

urlpatterns = [
    path('admin/', admin.site.urls),
]

if settings.DEBUG:
    urlpatterns.append(path('__debug__/', include('debug_toolbar.urls')))
EOF

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
    source "$venv_path/bin/activate"
    sudo chown "${USER}:${USER}" "${project_path}/${project_name}/staticfiles"
    python "${project_path}/${project_name}/manage.py" collectstatic --noinput
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to collect static files."
        deactivate
        exit 1
    fi
    sudo chown -R www-data:www-data "${project_path}/${project_name}/staticfiles"
    deactivate
fi

# Configure Gunicorn
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Gunicorn configuration..."
gunicorn_socket="${project_path}/conf/gunicorn/${project_name}.gunicorn.socket"
gunicorn_service="${project_path}/conf/gunicorn/${project_name}.gunicorn.service"

cat <<EOF | sudo tee "${gunicorn_socket}" > /dev/null
[Unit]
Description=gunicorn socket

[Socket]
ListenStream=/run/${project_name}.gunicorn.sock

[Install]
WantedBy=sockets.target
EOF
sudo chmod 644 "${gunicorn_socket}"

cat <<EOF | sudo tee "${gunicorn_service}" > /dev/null
[Unit]
Description=gunicorn daemon
Requires=${project_name}.gunicorn.socket
After=network.target

[Service]
UMask=002
User=www-data
Group=www-data
WorkingDirectory=${project_path}/${project_name}
EnvironmentFile=${project_path}/conf/env_vars/${environment}.env
ExecStart=${venv_path}/bin/gunicorn \\
    --access-logfile ${project_path}/log/gunicorn.log \\
    --error-logfile ${project_path}/log/gunicorn.log \\
    --capture-output \\
    --workers 3 \\
    --bind unix:/run/${project_name}.gunicorn.sock \\
    config.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
sudo chmod 644 "${gunicorn_service}"

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
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to enable Gunicorn service."
    exit 1
fi

# Start and enable Gunicorn socket with status check
sudo systemctl start "${project_name}.gunicorn.socket"
if ! sudo systemctl is-active "${project_name}.gunicorn.socket" > /dev/null; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to start Gunicorn socket."
    exit 1
fi
sudo systemctl enable "${project_name}.gunicorn.socket"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to enable Gunicorn socket."
    exit 1
fi

# Configure Nginx configuration for Docker
echo -e "\e[38;5;72m[INFO]\e[0m Setting up Nginx configuration..."
# Create nginx.conf for Docker environment
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

# Create <project_name>.conf for Docker environment
docker_project_conf="${project_path}/conf/nginx/docker/${project_name}.conf"
cat <<EOF | sudo tee "${docker_project_conf}" > /dev/null
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
sudo chmod 644 "${docker_project_conf}"

# Create nginx.conf for local environment
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

# Create <project_name>.conf for local environment
local_project_conf="${project_path}/conf/nginx/local/${project_name}.conf"
cat <<EOF | sudo tee "${local_project_conf}" > /dev/null
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
sudo chmod 644 "${local_project_conf}"
sudo install -m 644 "${local_project_conf}" /etc/nginx/sites-available/${project_name}.conf
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install project-specific Nginx configuration for ${project_name}."
    exit 1
fi

# Reload systemd to apply changes
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload systemd daemon for Nginx."
    exit 1
fi

# Create a symbolic link for Nginx configuration
if [[ ! -f "/etc/nginx/sites-enabled/${project_name}.conf" ]]; then
    sudo ln -sf "${local_project_conf}" "/etc/nginx/sites-enabled/${project_name}.conf"
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