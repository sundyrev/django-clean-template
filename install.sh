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

    # Проверка допустимых значений
    if [[ "$env" != "dev" && "$env" != "development" && "$env" != "production" ]]; then
        echo "Invalid environment. Please choose 'development' or 'production'"
        return 1
    fi

    # Нормализация значения (упрощённая логика)
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
mkdir -m 755 -p "${project_path}/conf/"{nginx,gunicorn,env_vars}
install -m 644 /dev/null "${project_path}/conf/nginx/${project_name}.nginx.conf"
install -m 644 /dev/null "${project_path}/conf/gunicorn/${project_name}.gunicorn.socket"
install -m 644 /dev/null "${project_path}/conf/gunicorn/${project_name}.gunicorn.service"
mkdir -m 755 -p "${project_path}/${project_name}/"{apps,templates,media,jinja2}
mkdir -m 755 -p "${project_path}/log"
mkdir -m 755 -p "${project_path}/${project_name}/requirements"

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
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx.log"
sudo install -m 664 -o www-data -g www-data /dev/null "${project_path}/log/nginx_error.log"
sudo install -m 664 -o "${USER}" -g www-data /dev/null "${project_path}/log/gunicorn.log"
sudo install -m 664 -o "${USER}" -g www-data /dev/null "${project_path}/log/django.log"

# Create Docker files
# install -m 664 /dev/null "${project_path}/docker-compose.yml"
# mkdir -m 755 -p "${project_path}/docker"
# install -m 664 /dev/null "${project_path}/docker/Dockerfile.dev"
# install -m 664 /dev/null "${project_path}/docker/Dockerfile.prod"

# Configure environment variables
echo -e "\e[32m[INFO]\e[0m Configuring environment variables..."

# Create local environment file with proper permissions
install -m 644 /dev/null "${project_path}/conf/env_vars/local.env"
cat > "${project_path}/conf/env_vars/local.env" << EOL
DEBUG=True
#SECRET_KEY=insert-your-secret-key-here
ALLOWED_HOSTS=${project_domain},localhost,127.0.0.1
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
POSTGRES_DB=${project_name}_db
POSTGRES_USER=${project_name}_user
POSTGRES_PASSWORD=${project_name}_password
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
EOL

# Create .gitignore file
install -m 644 /dev/null "${project_path}/.gitignore"
cat > "${project_path}/.gitignore" << EOL
# Ignore files and directories related to Python
__pycache__/
*.py[cod]
*.sqlite3
*.log
*.pot
*.pyc
*.pyo
*.pyd
*.db
*.egg-info/
*.egg
dist/
build/
.cache/
.pytest_cache/
.coverage
.idea/
.vscode/
.DS_Store

# Ignore files and directories related to Django
/media/
/static/
/log/
/env/
.env
local.env
production.env

# Ignore files related to Docker
docker-compose.override.yml
docker-compose.prod.yml
docker-compose.dev.yml

# Ignore files related to IDE
.idea/
.vscode/

# Ignore files related to the operating system
.DS_Store
Thumbs.db

# Ignore compiled requirements
requirements/*.txt
!requirements/base.txt
!requirements/local.txt
!requirements/production.txt
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
mkdir -m 755 -p apps media

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
sed -i "1,/from pathlib import Path/c\import environ\nfrom pathlib import Path" "${settings_path}"

# Update BASE_DIR definition
sed -i "s|BASE_DIR = Path(__file__).resolve().parent.parent|BASE_DIR = Path(__file__).resolve().parent.parent.parent\n\nenv = environ.Env()\nenv.read_env(env_file=BASE_DIR / 'conf/env_vars/${environment}.env')|" "${settings_path}"

# Add environment-based SECRET_KEY setting
sed -i "/SECRET_KEY =/a # SECRET_KEY= env('SECRET_KEY')" "${settings_path}"

# Update DEBUG setting
sed -i "s/DEBUG = True/DEBUG = env.bool('DEBUG', default=False)/" "${settings_path}"

# Update ALLOWED_HOSTS setting
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = env.list('ALLOWED_HOSTS', default=\['localhost', '127.0.0.1'\])/" "${settings_path}"

# Update STATIC_URL and STATIC_ROOT setting
sed -i "/STATIC_URL = ['\"]static\/['\"]/c\STATIC_URL = 'static\/'\nSTATIC_ROOT = BASE_DIR / 'static'" "${settings_path}"

# Update TEMPLATES setting
cat > config/settings_templates.py << 'EOF'
TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.jinja2.Jinja2',
        'DIRS': [BASE_DIR / 'jinja2'],
        'APP_DIRS': True,
        'OPTIONS': {
            'environment': 'config.jinja2.environment',
        },
    },
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
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
        'HOST': env('POSTGRES_HOST',  default='localhost'),
        'PORT': env('POSTGRES_PORT',  default='5432'),
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
# Logging
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'file': {
            'level': 'DEBUG',
            'class': 'logging.FileHandler',
            'filename': BASE_DIR / 'log/django.log',
        },
    },
    'loggers': {
        'django': {
            'handlers': ['file'],
            'level': 'DEBUG',
            'propagate': True,
        },
    },
}
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

sudo ln -s "${gunicorn_service}" "/etc/systemd/system/${project_name}.gunicorn.service"
sudo ln -s "${gunicorn_socket}" "/etc/systemd/system/${project_name}.gunicorn.socket"
sudo systemctl daemon-reload 

sudo systemctl start "${project_name}.gunicorn.service"
sudo systemctl enable "${project_name}.gunicorn.service"
sudo systemctl start "${project_name}.gunicorn.socket"
sudo systemctl enable "${project_name}.gunicorn.socket"

# Configure Nginx
echo -e "\e[32m[INFO]\e[0m Setting up Nginx configuration..."
nginx_conf="${project_path}/conf/nginx/${project_name}.nginx.conf"

cat <<EOF > "${nginx_conf}"
server {
    listen 80;
    server_name ${project_domain};

    access_log ${project_path}/log/nginx.log;
    error_log ${project_path}/log/nginx_error.log;

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location /static/ {
        root ${project_path}/${project_name};
    }

    location /media/ {
        autoindex on;
        alias ${project_path}/${project_name}/media/;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/${project_name}.gunicorn.sock;
    }
}
EOF

sudo ln -s "${nginx_conf}" /etc/nginx/sites-enabled
sudo nginx -t && sudo systemctl restart nginx
echo -e "\e[32m[INFO]\e[0m Django project setup completed successfully."