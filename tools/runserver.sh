#!/bin/bash
set -e

# ============================================
# Script to run Django development server
# ============================================
# This script stops the Gunicorn sockets and services for both "local" and "production"
# instances (if running), syncs dependencies for the local environment, activates the
# project's virtual environment, and starts the Django development server for the
# specified project. It ensures the project directory, virtual environment, and
# requirements file exist before proceeding.

# Usage: runserver.sh [--project PROJECT_NAME]
#   --project PROJECT_NAME: Name of the Django project folder

# Function to display usage information
usage() {
    echo "Usage: $0 [--project PROJECT_NAME]"
    echo "  --project  Project name. If not specified, it will be prompted from the user."
    exit 1
}

# Parse command-line parameters
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --project)
            if [[ -n "$2" && "$2" != --* ]]; then
                project_name="$2"
                shift 2
            else
                echo -e "\e[38;5;196m[ERROR]\e[0m The --project parameter requires a value."
                usage
            fi
            ;;
        *)
            echo -e "\e[38;5;196m[ERROR]\e[0m Unknown parameter: $1"
            usage
            ;;
    esac
done

# If project_name is not specified, prompt the user
if [[ -z "$project_name" ]]; then
    read -e -p "Project name: " project_name
    if [[ -z "${project_name}" ]]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Project name is required."
        exit 1
    fi
fi

# Check for project path in environment variable or prompt the user
project_path_var="${project_name^^}_PATH"
project_path="${!project_path_var}"

if [[ -n "$project_path" ]]; then
    project_path="${project_path/#\~/$HOME}"
fi

if [[ -z "$project_path" ]]; then
    read -e -p "Project path: " project_path
    project_path="${project_path/#\~/$HOME}"
    project_path=$(realpath -m "${project_path}")
fi

if [[ -z "${project_path}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project path is required."
    exit 1
fi

if [[ ! -d "${project_path}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Project directory not found at \e[38;5;223m${project_path}\e[0m."
    exit 1
fi

if [[ ! -d "${project_path}/env" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at \e[38;5;223m${project_path}/env\e[0m."
    exit 1
fi

# Check for local requirements file
requirements_file="${project_path}/${project_name}/requirements/local.txt"
if [[ ! -f "${requirements_file}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Local requirements file not found at \e[38;5;223m${requirements_file}\e[0m."
    exit 1
fi

# Define environments for Gunicorn instances
envs=("local" "production")

# Stop Gunicorn sockets and services for both environments
for env in "${envs[@]}"; do
    socket_unit="${project_name}.gunicorn@${env}.socket"
    service_unit="${project_name}.gunicorn@${env}.service"

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
done

echo -e "\e[38;5;72m[INFO]\e[0m Activating virtual environment..."
if [[ -f "${project_path}/env/bin/activate" ]]; then
    source "${project_path}/env/bin/activate"
    if [[ -z "$VIRTUAL_ENV" ]]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to activate virtual environment at \e[38;5;223m${project_path}/env\e[0m."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Virtual environment activated."
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Activation script not found at \e[38;5;223m${project_path}/env/bin/activate\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Syncing local dependencies..."
uv pip sync "${requirements_file}"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to sync local dependencies from \e[38;5;223m${requirements_file}\e[0m."
    exit 1
fi
echo -e "\e[38;5;72m[INFO]\e[0m Local dependencies synced successfully."

export DJANGO_SETTINGS_MODULE=config.settings.local

echo -e "\e[38;5;72m[INFO]\e[0m Running Django development server..."
if [[ -f "${project_path}/${project_name}/manage.py" ]]; then
    python "${project_path}/${project_name}/manage.py" runserver 0.0.0.0:8000
else
    echo -e "\e[38;5;196m[ERROR]\e[0m manage.py not found at \e[38;5;223m${project_path}/${project_name}/manage.py\e[0m."
    exit 1
fi