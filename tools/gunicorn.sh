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

echo -e "\e[38;5;72m[INFO]\e[0m Stopping Django development server (if running)..."
if pgrep -f "manage.py runserver" > /dev/null; then
    pkill -f "manage.py runserver"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Django development server."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Django development server stopped."
else
    echo -e "\e[38;5;208m[WARNING]\e[0m No Django development server running."
fi

echo -e "\e[38;5;72m[INFO]\e[0m Starting Gunicorn..."
if systemctl list-unit-files | grep -q "${project_name}.gunicorn.service"; then
    sudo systemctl start "${project_name}.gunicorn.service"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to start Gunicorn service."
        exit 1
    fi
    if ! sudo systemctl is-active "${project_name}.gunicorn.service" > /dev/null; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn service failed to activate."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Gunicorn service started successfully."
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn service '${project_name}.gunicorn.service' not found."
    exit 1
fi