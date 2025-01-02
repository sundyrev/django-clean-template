#!/bin/bash

read -p "Project name: " project_name
read -p "Project path: " project_path
if [[ -z "$project_path" ]]; then
    echo "Error: Project path is required."
    exit 1
fi

read -p "Are you sure you want to delete the project at $project_path? [y/N]: " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Deletion canceled."
    exit 0
fi

# Check if the project path matches the script's directory
script_dir=$(dirname "$(realpath "$0")")
if [[ "$project_path" == "$script_dir" ]]; then
    echo "Error: Cannot delete the script's directory ($script_dir)."
    exit 1
fi

echo "Stopping the Gunicorn socket..."
sudo systemctl stop ${project_name}.gunicorn.socket &>/dev/null

echo "Stopping the Gunicorn service..."
sudo systemctl stop ${project_name}.gunicorn.service &>/dev/null

echo "Disabling the Gunicorn service and socket..."
sudo systemctl disable ${project_name}.gunicorn.service &>/dev/null
sudo systemctl disable ${project_name}.gunicorn.socket &>/dev/null

echo "Removing symbolic links for the Gunicorn service and socket..."
sudo find /etc/systemd/system -type l -name "${project_name}.gunicorn.*" -delete

echo "Reloading systemd to refresh the configuration..."
sudo systemctl daemon-reload &>/dev/null

echo "Removing Nginx configuration..."
if [[ -f "/etc/nginx/sites-enabled/${project_name}.nginx.conf" ]]; then
    sudo rm "/etc/nginx/sites-enabled/${project_name}.nginx.conf" &>/dev/null
    sudo systemctl reload nginx &>/dev/null
fi

if [[ -d "$project_path" ]]; then
    echo "Deleting the project folder $project_path..."
    sudo rm -rf "$project_path"
else
    echo "Project folder $project_path does not exist."
fi

echo "The project has been successfully deleted!"
