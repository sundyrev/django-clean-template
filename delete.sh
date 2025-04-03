#!/bin/bash
set -e

read -e -p "Project name: " project_name
if [[ -z "${project_name}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project name is required."
    exit 1
fi
read -e -p "Project path: " project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "${project_path}")

if [[ -z "${project_path}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Project path is required."
    exit 1
fi

echo -e "Are you sure you want to delete the project at \e[33m${project_path}\e[0m? \e[95m[y/N]\e[0m: \c"
read -e confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo -e "\e[90m[INFO]\e[0m Deletion canceled."
    exit 0
fi

# Check if the project path matches the script's directory
script_dir=$(dirname "$(realpath "$0")")
if [[ "${project_path}" == "${script_dir}" ]]; then
    echo -e "\e[31m[ERROR]\e[0m Cannot delete the script's directory \e[33m\"${script_dir}\"\e[0m."
    exit 1
fi

echo -e "\e[90m[INFO]\e[0m Stopping the Gunicorn socket..."
if systemctl --quiet is-active "${project_name}.gunicorn.socket"; then
    sudo systemctl stop "${project_name}.gunicorn.socket"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR]\e[0m Failed to stop Gunicorn socket."
        exit 1
    fi
else
    echo -e "\e[93m[WARNING]\e[0m Gunicorn socket is not active, skipping stop."
fi

echo -e "\e[90m[INFO]\e[0m Stopping the Gunicorn service..."
if systemctl --quiet is-active "${project_name}.gunicorn.service"; then
    sudo systemctl stop "${project_name}.gunicorn.service"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR]\e[0m Failed to stop Gunicorn service."
        exit 1
    fi
else
    echo -e "\e[93m[WARNING]\e[0m Gunicorn service is not active, skipping stop."
fi

echo -e "\e[90m[INFO]\e[0m Disabling the Gunicorn service and socket..."
if systemctl list-unit-files | grep -q "${project_name}.gunicorn.service"; then
    sudo systemctl disable "${project_name}.gunicorn.service" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR]\e[0m Failed to disable Gunicorn service."
        exit 1
    fi
fi
if systemctl list-unit-files | grep -q "${project_name}.gunicorn.socket"; then
    sudo systemctl disable "${project_name}.gunicorn.socket" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR]\e[0m Failed to disable Gunicorn socket."
        exit 1
    fi
fi

echo -e "\e[90m[INFO]\e[0m Removing Gunicorn service and socket files..."
for file in "/etc/systemd/system/${project_name}.gunicorn.service" "/etc/systemd/system/${project_name}.gunicorn.socket"; do
    if [[ -f "$file" ]]; then
        sudo rm -f "$file"
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[ERROR]\e[0m Failed to remove $file."
            exit 1
        fi
    fi
done

echo -e "\e[90m[INFO]\e[0m Reloading systemd to refresh the configuration..."
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[31m[ERROR]\e[0m Failed to reload systemd daemon."
    exit 1
fi

echo -e "\e[90m[INFO]\e[0m Removing Nginx configuration..."
nginx_config="/etc/nginx/sites-enabled/${project_name}.conf"
if [[ -f "${nginx_config}" ]]; then
    sudo rm -f "${nginx_config}"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR]\e[0m Failed to remove Nginx configuration ${nginx_config}."
        exit 1
    fi
    echo -e "\e[90m[INFO]\e[0m Reloading Nginx after configuration removal..."
    if sudo nginx -t &>/dev/null; then
        sudo systemctl reload nginx
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[ERROR]\e[0m Failed to reload Nginx service."
            exit 1
        fi
    else
        echo -e "\e[31m[ERROR]\e[0m Nginx configuration test failed after removal."
        exit 1
    fi
else
    echo -e "\e[93m[WARNING]\e[0m No Nginx configuration found at ${nginx_config}, skipping removal."
fi

if [[ -d "${project_path}" ]]; then
    echo -e "\e[90m[INFO]\e[0m Deleting the project folder \e[33m${project_path}\e[0m..."
    sudo rm -rf "${project_path}"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[ERROR]\e[0m Failed to delete project folder \"${project_path}\"."
        exit 1
    fi
else
    echo -e "\e[93m[WARNING]\e[0m Project folder \"${project_path}\" does not exist, skipping deletion."
fi

echo -e "\e[32m[SUCCESS]\e[0m The project has been successfully deleted!"