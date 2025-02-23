#!/bin/bash

read -e -p "Project name: " project_name
read -e -p "Project path: " project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "${project_path}")

if [[ -z "${project_path}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project path is required."
    exit 1
fi

echo -e "\e[32m[INFO]\e[0m Stopping Gunicorn..."
sudo systemctl stop "${project_name}.gunicorn.service"

echo -e "\e[32m[INFO]\e[0m Activating virtual environment..."
source "${project_path}/env/bin/activate"

echo -e "\e[32m[INFO]\e[0m Running Django development server..."
python "${project_path}/nowknow/manage.py" runserver 0.0.0.0:8000
