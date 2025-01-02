#!/bin/bash
service_name="nowknow"
project_path="/home/alexey/projects/nowknowApp"

read -p "Are you sure you want to delete the project $project_path? [y/N]: " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Deletion canceled."
    exit 0
fi

echo "Stopping the Gunicorn socket..."
sudo systemctl stop ${service_name}.gunicorn.socket &>/dev/null

echo "Stopping the Gunicorn service..."
sudo systemctl stop ${service_name}.gunicorn.service &>/dev/null

echo "Disabling the Gunicorn service and socket..."
sudo systemctl disable ${service_name}.gunicorn.service &>/dev/null
sudo systemctl disable ${service_name}.gunicorn.socket &>/dev/null

echo "Removing symbolic links for the Gunicorn service and socket..."
sudo find /etc/systemd/system -type l -name "${service_name}.gunicorn.*" -delete

echo "Reloading systemd to refresh the configuration..."
sudo systemctl daemon-reload &>/dev/null

echo "Removing Nginx configuration..."
if [[ -f "/etc/nginx/sites-enabled/${service_name}.nginx.conf" ]]; then
    sudo rm "/etc/nginx/sites-enabled/${service_name}.nginx.conf" &>/dev/null
    sudo systemctl reload nginx &>/dev/null
fi

if [[ -d "$project_path" ]]; then
    echo "Deleting the project folder $project_path..."
    sudo rm -rf "$project_path"
else
    echo "Project folder $project_path does not exist."
fi

echo "The project has been successfully deleted!"
