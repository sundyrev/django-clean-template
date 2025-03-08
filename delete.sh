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
sudo systemctl stop ${project_name}.gunicorn.socket &>/dev/null

echo -e "\e[32m[INFO]\e[0m Stopping the Gunicorn service..."
sudo systemctl stop ${project_name}.gunicorn.service &>/dev/null

echo -e "\e[32m[INFO]\e[0m Disabling the Gunicorn service and socket..."
sudo systemctl disable ${project_name}.gunicorn.service &>/dev/null
sudo systemctl disable ${project_name}.gunicorn.socket &>/dev/null

echo -e "\e[32m[INFO]\e[0m Removing symbolic links for the Gunicorn service and socket..."
sudo find /etc/systemd/system -type l -name "${project_name}.gunicorn.*" -delete

echo -e "\e[32m[INFO]\e[0m Reloading systemd to refresh the configuration..."
sudo systemctl daemon-reload &>/dev/null

echo -e "\e[32m[INFO]\e[0m Removing Nginx configuration..."
# Remove project-specific nginx config
configs=("nginx.conf" "${project_name}.conf" "docker.conf")
for conf in "${configs[@]}"; do
    for dir in "/etc/nginx/sites-enabled" "/etc/nginx/sites-available"; do
        if [[ -f "${dir}/$conf" ]]; then
            # echo -e "\e[32m[INFO]\e[0m Removing $conf from $dir..."
            sudo rm "${dir}/$conf" &>/dev/null
        fi
    done
done

# Reload nginx after removing configs
sudo systemctl reload nginx &>/dev/null

if [[ -d "$project_path" ]]; then
    echo -e "\e[32m[INFO]\e[0m Deleting the project folder $project_path..."
    sudo rm -rf "$project_path"
else
    echo -e "\e[31m[ERROR]\e[0m Project folder $project_path does not exist."
fi

echo -e "\e[32m[INFO]\e[0m The project has been successfully deleted!"