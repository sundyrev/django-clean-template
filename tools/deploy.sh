#!/bin/bash
set -e

read -e -p "Project name: " project_name
if [[ -z "${project_name}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project name is required."
    exit 1
fi

read -e -p "Project path: " project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "${project_path}")

if [[ -z "${project_path}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project path is required."
    exit 1
fi

if [[ ! -d "${project_path}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project directory not found at \e[38;5;223m${project_path}\e[0m."
    exit 1
fi

if [[ ! -d "${project_path}/env" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at \e[38;5;223m${project_path}/env\e[0m."
    exit 1
fi

if [[ ! -f "${project_path}/${project_name}/requirements/production.txt" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Production requirements file not found at \e[38;5;223m${project_path}/${project_name}/requirements/production.txt\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Changing to project directory \e[38;5;223m${project_path}\e[0m..."
cd "${project_path}" || {
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to change to directory \e[38;5;223m${project_path}\e[0m."
    exit 1
}

echo -e "\e[38;5;72m[INFO]\e[0m Updating code from Git..."
if [[ -d ".git" ]]; then
    git pull origin main
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update code from Git."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m No Git repository found in \e[38;5;223m${project_path}\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Activating virtual environment..."
if [[ -f "${project_path}/env/bin/activate" ]]; then
    source "${project_path}/env/bin/activate"
    if [[ -z "$VIRTUAL_ENV" ]]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to activate virtual environment at \e[38;5;223m${project_path}/env\e[0m."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Activation script not found at \e[38;5;223m${project_path}/env/bin/activate\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Updating dependencies..."
pip-sync "${project_path}/${project_name}/requirements/production.txt"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to update dependencies with pip-sync."
    exit 1
fi

export DJANGO_SETTINGS_MODULE=config.settings.production

echo -e "\e[38;5;72m[INFO]\e[0m Applying migrations..."
if [[ -f "${project_path}/${project_name}/manage.py" ]]; then
    python "${project_path}/${project_name}/manage.py" migrate
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to apply migrations."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m manage.py not found at \e[38;5;223m${project_path}/${project_name}/manage.py\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Collecting static files..."
if [[ -f "${project_path}/${project_name}/manage.py" ]]; then
    python "${project_path}/${project_name}/manage.py" collectstatic --noinput
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to collect static files."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m manage.py not found at \e[38;5;223m${project_path}/${project_name}/manage.py\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Deactivating virtual environment..."
deactivate

echo -e "\e[38;5;72m[INFO]\e[0m Restarting Gunicorn..."
if systemctl list-unit-files | grep -q "${project_name}.gunicorn.service"; then
    sudo systemctl restart "${project_name}.gunicorn.service"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to restart Gunicorn service."
        exit 1
    fi
    if ! sudo systemctl is-active "${project_name}.gunicorn.service" > /dev/null; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn service failed to activate after restart."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn service '${project_name}.gunicorn.service' not found."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Reloading Nginx..."
if sudo nginx -t &>/dev/null; then
    sudo systemctl reload nginx
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload Nginx service."
        exit 1
    fi
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Nginx configuration test failed."
    exit 1
fi

echo -e "\e[38;5;48m[SUCCESS]\e[0m Deployment completed!"