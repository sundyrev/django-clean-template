#!/bin/bash
set -e

read -e -p "Project name: " project_name
read -e -p "Project path: " project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "${project_path}")

if [[ -z "${project_path}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project path is required."
    exit 1
fi

if [[ ! -d "${project_path}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project directory not found at \e[33m\"${project_path}\"\e[0m."
    exit 1
fi

if [[ ! -d "${project_path}/env" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Virtual environment not found at \e[33m\"${project_path}/env\"\e[0m."
    exit 1
fi

if [[ ! -f "${project_path}/${project_name}/requirements/production.txt" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Production requirements file not found at \e[33m\"${project_path}/${project_name}/requirements/production.txt\"\e[0m."
    exit 1
fi

cd "${project_path}"

echo -e "\e[90m[INFO]\e[0m Updating code from Git..."
git pull origin main

echo -e "\e[90m[INFO]\e[0m Activating virtual environment..."
source "${project_path}/env/bin/activate"

echo -e "\e[90m[INFO]\e[0m Updating dependencies..."
pip-sync "${project_path}/${project_name}/requirements/production.txt"

export DJANGO_SETTINGS_MODULE=config.settings.production

echo -e "\e[90m[INFO]\e[0m Applying migrations..."
python "${project_path}/${project_name}/manage.py" migrate

echo -e "\e[90m[INFO]\e[0m Collecting static files..."
python "${project_path}/${project_name}/manage.py" collectstatic --noinput

deactivate

echo -e "\e[90m[INFO]\e[0m Restarting Gunicorn..."
sudo systemctl restart "${project_name}.gunicorn"

echo -e "\e[90m[INFO]\e[0m Reloading Nginx..."
sudo systemctl reload nginx

echo -e "\e[32m[SUCCESS]\e[0m Deployment completed!"