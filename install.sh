#!/bin/bash

# Check if pyenv is installed
if ! command -v pyenv &> /dev/null; then
    echo "pyenv is not installed. Please install it before proceeding."
    exit 1
fi

# Variables
default_python_interpreter=$(which python3)
project_domain=""
project_path=$(pwd)
project_name=""

# Prompt for user input
read -p "Python interpreter (default: $default_python_interpreter): " base_python_interpreter
read -p "Your domain without protocol (e.g., example.com): " project_domain
read -p "Project name: " project_name

# Set defaults if not provided
base_python_interpreter=${base_python_interpreter:-$default_python_interpreter}

# Install necessary packages
echo "[INFO] Installing necessary packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-pip python3-dev libpq-dev postgresql postgresql-contrib nginx curl

# Create the directory structure
echo "[INFO] Creating project directory structure..."
mkdir -p $project_path/conf/{nginx,gunicorn,env_vars}
touch $project_path/conf/nginx/$project_name.nginx.conf
touch $project_path/conf/gunicorn/{$project_name.gunicorn.socket,$project_name.gunicorn.service}
mkdir -p $project_path/$project_name/{apps,templates,media,jinja2}
mkdir -p $project_path/log
touch $project_path/log/{django.log,gunicorn.log,nginx.log,nginx_error.log}

echo "[INFO] Setting permissions for Gunicorn configuration files..."
sudo chmod 644 $project_path/conf/gunicorn/$project_name.gunicorn.{service,socket}

# Set permissions for log directory
echo "[INFO] Setting permissions for log directory..."
sudo chown $USER:www-data $project_path/log 
sudo chmod 775 $project_path/log

# Set permissions for log files
echo "[INFO] Setting permissions for log files..."
sudo chown www-data:www-data $project_path/log/{nginx.log,nginx_error.log}
sudo chown $USER:www-data $project_path/log/{gunicorn.log,django.log}
sudo chmod 664 $project_path/log/{nginx.log,nginx_error.log,gunicorn.log,django.log}

# Configure environment variables
echo "[INFO] Configuring environment variables..."
env_file=$project_path/conf/env_vars/deploy.env
touch $env_file
echo "export DB_NAME=${project_name}_db" >> $env_file
echo "export DB_USER=${project_name}_user" >> $env_file
echo "export DB_PASSWORD=${project_name}_password" >> $env_file
echo "export DB_HOST=localhost" >> $env_file
echo "export DB_PORT=5432" >> $env_file

# Set up Python virtual environment
echo "[INFO] Setting up Python virtual environment..."
cd $project_path
$base_python_interpreter -m venv env
source env/bin/activate

# Upgrade pip to the latest version and install all dependencies
pip install --upgrade pip
pip install -r requirements.txt

# Install Django and Gunicorn
echo "[INFO] Installing Django and Gunicorn in the virtual environment..."
pip install django gunicorn

# Create Django project
echo "[INFO] Creating Django project..."
django-admin startproject config $project_name
cd $project_name
mkdir -p apps templates media jinja2
touch templates/base.html
touch jinja2/j2.login.html

echo "[INFO] Setting up applications directory..."
touch apps/__init__.py

# Update settings.py
echo "[INFO] Updating Django settings..."
settings_file=config/settings.py
sed -i "s/ALLOWED_HOSTS = .*/ALLOWED_HOSTS = ['$project_domain']/" $settings_file
sed -i "s|STATIC_URL = 'static/'|STATIC_URL = '/static/'\nSTATIC_ROOT = BASE_DIR / 'static/'|" $settings_file

# Collect static files
echo "[INFO] Collecting static files..."
python manage.py collectstatic --noinput

# Generate requirements.txt
echo "[INFO] Generating requirements.txt..."
pip freeze > requirements.txt

# Configure Gunicorn
echo "[INFO] Setting up Gunicorn configuration..."
gunicorn_socket=$project_path/conf/gunicorn/$project_name.gunicorn.socket
gunicorn_service=$project_path/conf/gunicorn/$project_name.gunicorn.service
touch $gunicorn_socket
cat <<EOF > $gunicorn_socket
[Unit]
Description=gunicorn socket

[Socket]
ListenStream=/run/$project_name.gunicorn.sock

[Install]
WantedBy=sockets.target
EOF

touch $gunicorn_service
cat <<EOF > $gunicorn_service
[Unit]
Description=gunicorn daemon
Requires=$project_name.gunicorn.socket
After=network.target

[Service]
User=$USER
Group=www-data
WorkingDirectory=$project_path/$project_name
ExecStart=$project_path/env/bin/gunicorn \
          --access-logfile $project_path/log/gunicorn.log \
          --error-logfile $project_path/log/gunicorn.log \
          --capture-output \
          --workers 3 \
          --bind unix:/run/$project_name.gunicorn.sock config.wsgi:application

[Install]
WantedBy=multi-user.target
EOF

sudo ln -s $gunicorn_service /etc/systemd/system/$project_name.gunicorn.service
sudo ln -s $gunicorn_socket /etc/systemd/system/$project_name.gunicorn.socket
sudo systemctl daemon-reload 

sudo systemctl start $project_name.gunicorn.service
sudo systemctl enable $project_name.gunicorn.service
sudo systemctl start $project_name.gunicorn.socket
sudo systemctl enable $project_name.gunicorn.socket

# Configure Nginx
echo "[INFO] Setting up Nginx configuration..."
nginx_conf=$project_path/conf/nginx/$project_name.nginx.conf
touch $nginx_conf
cat <<EOF > $nginx_conf
server {
    listen 80;
    server_name $project_domain;

    access_log $project_path/log/nginx.log;
    error_log $project_path/log/nginx_error.log;

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location /static/ {
        root $project_path/$project_name;
    }

    location /media/ {
        autoindex on;
        alias $project_path/$project_name/media/;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/$project_name.gunicorn.sock;
    }
}
EOF

sudo ln -s $nginx_conf /etc/nginx/sites-enabled
sudo nginx -t && sudo systemctl restart nginx

echo "[INFO] Django project setup completed successfully."
