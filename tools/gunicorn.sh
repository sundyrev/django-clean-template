#!/bin/bash

project_name="nowknow"
project_path=$(dirname "$(realpath "$0")")

echo -e "\e[32m[INFO]\e[0m Stopping Django development server (if running)..."
pkill -f "manage.py runserver"

echo -e "\e[32m[INFO]\e[0m Starting Gunicorn..."
sudo systemctl start "${project_name}.gunicorn.service"
