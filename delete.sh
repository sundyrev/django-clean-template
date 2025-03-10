#!/bin/bash

read -e -p "Project name: " project_name
if [[ -z "$project_name" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project name is required."
    exit 1
fi
read -e -p "Project path: " project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "$project_path")

if [[ -z "$project_path" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project path is required."
    exit 1
fi

read -e -p "Are you sure you want to delete the project at ${project_path}? [y/N]: " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo -e "\e[32m[INFO]\e[0m Deletion canceled."
    exit 0
fi

# Check if the project path matches the script's directory
script_dir=$(dirname "$(realpath "$0")")
if [[ "$project_path" == "$script_dir" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Cannot delete the script's directory ($script_dir)."
    exit 1
fi

echo -e "\e[32m[INFO]\e[0m Stopping the Gunicorn socket..."
sudo systemctl stop "${project_name}.gunicorn.socket" &>/dev/null

echo -e "\e[32m[INFO]\e[0m Stopping the Gunicorn service..."
sudo systemctl stop "${project_name}.gunicorn.service" &>/dev/null

echo -e "\e[32m[INFO]\e[0m Disabling the Gunicorn service and socket..."
sudo systemctl disable "${project_name}.gunicorn.service" &>/dev/null
sudo systemctl disable "${project_name}.gunicorn.socket" &>/dev/null

# Remove systemd only if this service exists
if systemctl list-units --full --all | grep -q "${project_name}.gunicorn.service"; then
    echo -e "\e[32m[INFO]\e[0m Removing Gunicorn service and socket files..."
    sudo rm -f "/etc/systemd/system/${project_name}.gunicorn.service"
    sudo rm -f "/etc/systemd/system/${project_name}.gunicorn.socket"
fi

echo -e "\e[32m[INFO]\e[0m Reloading systemd to refresh the configuration..."
sudo systemctl daemon-reload &>/dev/null

echo -e "\e[32m[INFO]\e[0m Removing Nginx configuration..."
# Remove only the configuration of the current project
nginx_config="/etc/nginx/sites-enabled/${project_name}.conf"
if [[ -f "$nginx_config" ]]; then
    sudo rm "$nginx_config" &>/dev/null
fi

# Reload nginx after removing configs
sudo systemctl reload nginx &>/dev/null

if [[ -d "$project_path" ]]; then
    echo -e "\e[32m[INFO]\e[0m Deleting the project folder $project_path..."
    sudo rm -rf "$project_path"
else
    echo -e "\e[31m[ERROR]\e[0m Project folder $project_path does not exist."
fi

echo -e "\e[32m[INFO]\e[0m The project has been successfully deleted!"