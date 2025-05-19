#!/bin/bash
set -e

# ============================================
# Script to delete a Django project
# ============================================
# This script deletes a Django project, including its folder, virtual environment,
# PostgreSQL database and user, Gunicorn service/socket for both local and production,
# and Nginx configuration. It supports a local mode (--local) to skip server-related
# operations like Nginx. All actions are logged to a timestamped file, and user
# confirmation is required for critical steps.

# Usage: delete.sh [--local] [--project PROJECT_NAME]
#   --local: Skip Nginx operations for local development
#   --project PROJECT_NAME: Name of the Django project folder (prompted if not specified)

# Initialize variables
project_name=""
project_path=""
local_mode=false
timestamp=$(date +%F-%H%M%S)

# Parse command-line arguments for --local flag
if [[ "$1" == "--local" ]]; then
    local_mode=true
    shift
fi

# Prompt for project name
read -e -p $'\e[38;5;117m[1/3]\e[0m Project name: ' project_name
if [[ -z "${project_name}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project name is required."
    exit 1
fi

# Confirm project name to prevent typos
read -e -p $'\e[38;5;117m[2/3]\e[0m Confirm project name: ' confirm_project_name
if [[ "${project_name}" != "${confirm_project_name}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project names do not match."
    exit 1
fi

# Prompt for project path
read -e -p $'\e[38;5;117m[3/3]\e[0m Project path: ' project_path
project_path="${project_path/#\~/$HOME}"
project_path=$(realpath -m "${project_path}")

if [[ -z "${project_path}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project path is required."
    exit 1
fi

# Set up logging
log_file="/var/log/delete-${project_name}-${timestamp}.log"
if ! sudo touch "${log_file}"; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to create log file ${log_file}."
    exit 1
fi
sudo chmod 644 "${log_file}"
echo -e "\e[38;5;72m[INFO]\e[0m Logging operations to ${log_file}..."
exec > >(sudo tee -a "${log_file}") 2>&1

# Confirm project deletion
echo -e "Are you sure you want to delete the project \e[38;5;223m${project_name}\e[0m at \e[38;5;223m${project_path}\e[0m? \e[38;5;207m[y/N]\e[0m: \c"
read -e confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Deletion canceled."
    exit 0
fi

# Check if the project path matches the script's directory
script_dir=$(dirname "$(realpath "$0")")
if [[ "${project_path}" == "${script_dir}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Cannot delete the script's directory \e[38;5;223m\"${script_dir}\"\e[0m."
    exit 1
fi

# Define environments for Gunicorn instances
envs=("local" "production")

# Stop and disable Gunicorn instances for both environments
for env in "${envs[@]}"; do
    socket_unit="${project_name}.gunicorn@${env}.socket"
    service_unit="${project_name}.gunicorn@${env}.service"

    # Stop the socket if active
    if systemctl --quiet is-active "${socket_unit}"; then
        echo -e "\e[38;5;72m[INFO]\e[0m Stopping Gunicorn socket for ${env}..."
        sudo systemctl stop "${socket_unit}"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Gunicorn socket for ${env}."
            exit 1
        fi
    else
        echo -e "\e[38;5;208m[WARNING]\e[0m Gunicorn socket for ${env} is not active, skipping stop."
    fi

    # Stop the service if active
    if systemctl --quiet is-active "${service_unit}"; then
        echo -e "\e[38;5;72m[INFO]\e[0m Stopping Gunicorn service for ${env}..."
        sudo systemctl stop "${service_unit}"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Gunicorn service for ${env}."
            exit 1
        fi
    else
        echo -e "\e[38;5;208m[WARNING]\e[0m Gunicorn service for ${env} is not active, skipping stop."
    fi

    # Disable the socket if enabled
    if systemctl list-unit-files | grep -q "${socket_unit}"; then
        echo -e "\e[38;5;72m[INFO]\e[0m Disabling Gunicorn socket for ${env}..."
        sudo systemctl disable "${socket_unit}"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to disable Gunicorn socket for ${env}."
            exit 1
        fi
    fi

    # Disable the service if enabled (optional, for thoroughness)
    if systemctl list-unit-files | grep -q "${service_unit}"; then
        echo -e "\e[38;5;72m[INFO]\e[0m Disabling Gunicorn service for ${env}..."
        sudo systemctl disable "${service_unit}"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to disable Gunicorn service for ${env}."
            exit 1
        fi
    fi
done

# Remove Gunicorn template files
echo -e "\e[38;5;72m[INFO]\e[0m Removing Gunicorn template files..."
for file in "/etc/systemd/system/${project_name}.gunicorn@.service" "/etc/systemd/system/${project_name}.gunicorn@.socket"; do
    if [[ -f "$file" ]]; then
        sudo rm -f "$file"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to remove $file."
            exit 1
        fi
    fi
done

# Reload systemd to apply changes
echo -e "\e[38;5;72m[INFO]\e[0m Reloading systemd to refresh the configuration..."
sudo systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload systemd daemon."
    exit 1
fi

# Handle Nginx operations only if not in local mode
if [[ "${local_mode}" == false ]]; then
    # Remove Nginx configuration
    echo -e "\e[38;5;72m[INFO]\e[0m Removing Nginx configuration..."
    nginx_available_config="/etc/nginx/sites-available/${project_name}.conf"
    nginx_enabled_config="/etc/nginx/sites-enabled/${project_name}.conf"

    if [[ -f "${nginx_available_config}" ]]; then
        sudo rm -f "${nginx_available_config}"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to remove Nginx configuration from sites-available."
            exit 1
        fi
    fi

    if [[ -f "${nginx_enabled_config}" ]]; then
        sudo rm -f "${nginx_enabled_config}"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to remove Nginx configuration from sites-enabled."
            exit 1
        fi
    fi

    # Reload Nginx after configuration removal
    echo -e "\e[38;5;72m[INFO]\e[0m Reloading Nginx after configuration removal..."
    if systemctl --quiet is-active nginx; then
        if sudo nginx -t &>/dev/null; then
            sudo systemctl reload nginx
            if [ $? -ne 0 ]; then
                echo -e "\e[38;5;196m[ERROR]\e[0m Failed to reload Nginx service."
                exit 1
            fi
        else
            echo -e "\e[38;5;196m[ERROR]\e[0m Nginx configuration test failed after removal."
            exit 1
        fi
    else
        echo -e "\e[38;5;208m[WARNING]\e[0m Nginx service is not active, skipping reload."
    fi
fi

# Delete PostgreSQL database and user with separate confirmation
echo -e "Do you want to delete the PostgreSQL database \e[38;5;223m${project_name}_db\e[0m and user \e[38;5;223m${project_name}_user\e[0m? \e[38;5;207m[y/N]\e[0m: \c"
read -e db_confirm
if [[ "${db_confirm}" == "y" || "${db_confirm}" == "Y" ]]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Revoking privileges and resetting role settings..."
    sudo -u postgres psql -q -c "REVOKE ALL PRIVILEGES ON DATABASE ${project_name}_db FROM ${project_name}_user;" || {
        echo -e "\e[38;5;208m[WARNING]\e[0m Failed to revoke privileges, proceeding with deletion."
    }
    sudo -u postgres psql -q -c "ALTER ROLE ${project_name}_user RESET client_encoding;" || true
    sudo -u postgres psql -q -c "ALTER ROLE ${project_name}_user RESET default_transaction_isolation;" || true
    sudo -u postgres psql -q -c "ALTER ROLE ${project_name}_user RESET timezone;" || true

    echo -e "\e[38;5;72m[INFO]\e[0m Dropping PostgreSQL database ${project_name}_db..."
    sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS ${project_name}_db;" || {
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to drop database ${project_name}_db."
        exit 1
    }
    echo -e "\e[38;5;72m[INFO]\e[0m Dropping PostgreSQL user ${project_name}_user..."
    sudo -u postgres psql -q -c "DROP ROLE IF EXISTS ${project_name}_user;" || {
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to drop user ${project_name}_user."
        exit 1
    }
else
    echo -e "\e[38;5;72m[INFO]\e[0m Skipping PostgreSQL database and user deletion."
fi

# Delete virtual environment in /opt/${project_name} if it exists
if [[ -d "/opt/${project_name}" ]]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Deleting virtual environment \e[38;5;223m/opt/${project_name}\e[0m..."
    sudo rm -rf "/opt/${project_name}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to delete virtual environment /opt/${project_name}."
        exit 1
    fi
fi

# Delete the project folder
if sudo test -d "${project_path}"; then
    echo -e "\e[38;5;72m[INFO]\e[0m Deleting the project folder \e[38;5;223m${project_path}\e[0m..."
    sudo rm -rf "${project_path}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to delete project folder \e[38;5;223m\"${project_path}\"\e[0m. Check permissions or file system restrictions."
        exit 1
    fi
else
    echo -e "\e[38;5;208m[WARNING]\e[0m Project folder \e[38;5;223m${project_path}\e[0m does not exist, skipping deletion."
fi

echo -e "\e[38;5;48m[SUCCESS]\e[0m The project \e[38;5;223m${project_name}\e[0m has been successfully deleted!"