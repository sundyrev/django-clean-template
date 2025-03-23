#!/bin/bash

read -e -p "Project name: " project_name
read -e -p "Project path: " project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "${project_path}")

if [[ -z "${project_path}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project path is required."
    exit 1
fi

if [[ ! -d "${project_path}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project directory not found at ${project_path}."
    exit 1
fi

echo -e "\e[32m[INFO]\e[0m Stopping Django development server (if running)..."
pkill -f "manage.py runserver"

echo -e "\e[32m[INFO]\e[0m Starting Gunicorn..."
sudo systemctl start "${project_name}.gunicorn.service"
