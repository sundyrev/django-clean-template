#!/bin/bash
set -e

# ============================================
# Script to manage Gunicorn service for local or production environments
# ============================================
# This script stops the Django development server (if running), syncs dependencies
# for the specified environment (local or production), and starts the Gunicorn socket
# for the corresponding instance of the Django project. It ensures the project directory,
# virtual environment, and requirements file exist before starting.

# Usage: gunicorn.sh [--project PROJECT_NAME] [--dev]
#   --project PROJECT_NAME: Name of the Django project folder
#   --dev: Optional flag to activate local environment (defaults to production)

# Function to display usage information
usage() {
    echo "Usage: $0 [--project PROJECT_NAME] [--dev]"
    echo "  --project  Project name. If not specified, it will be prompted from the user."
    echo "  --dev      Activate local environment (defaults to production)."
    exit 1
}

# Parse command-line parameters
dev_mode=false
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
        --dev)
            dev_mode=true
            shift
            ;;
        *)
            echo -e "\e[38;5;196m[ERROR]\e[0m Unknown parameter: $1"
            usage
            ;;
    esac
done

# Set environment based on --dev flag
if [[ "$dev_mode" == true ]]; then
    environment="local"
else
    environment="production"
fi

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

# Check for virtual environment
if [[ ! -d "${project_path}/env" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at \e[38;5;223m${project_path}/env\e[0m."
    exit 1
fi

# Check for environment-specific requirements file
requirements_file="${project_path}/${project_name}/requirements/${environment}.txt"
if [[ ! -f "${requirements_file}" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m ${environment^} requirements file not found at \e[38;5;223m${requirements_file}\e[0m."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Stopping Django development server (if running)..."
if pgrep -f "manage.py runserver" > /dev/null; then
    pkill -f "manage.py runserver"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Django development server."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Django development server stopped."
else
    echo -e "\e[38;5;208m[WARNING]\e[0m No Django development server running."
fi

echo -e "\e[38;5;72m[INFO]\e[0m Stopping opposite environment (if running)..."
opposite_environment=$([[ "$environment" == "local" ]] && echo "production" || echo "local")
opposite_socket_unit="${project_name}.gunicorn@${opposite_environment}.socket"
if systemctl is-active --quiet "${opposite_socket_unit}"; then
    sudo systemctl stop "${opposite_socket_unit}"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Gunicorn socket for ${opposite_environment}."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Gunicorn socket for ${opposite_environment} stopped."
else
    echo -e "\e[38;5;208m[WARNING]\e[0m No Gunicorn socket for ${opposite_environment} running."
fi

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

echo -e "\e[38;5;72m[INFO]\e[0m Syncing ${environment} dependencies..."
uv pip sync "${requirements_file}"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to sync ${environment} dependencies from \e[38;5;223m${requirements_file}\e[0m."
    exit 1
fi
echo -e "\e[38;5;72m[INFO]\e[0m ${environment^} dependencies synced successfully."

echo -e "\e[38;5;72m[INFO]\e[0m Starting Gunicorn for ${environment}..."
socket_unit="${project_name}.gunicorn@${environment}.socket"

if ! systemctl list-unit-files | grep -q "${project_name}.gunicorn@.socket"; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn socket template '${project_name}.gunicorn@.socket' not found."
    exit 1
fi

# Enable and start the environment-specific socket
sudo systemctl enable --now "${socket_unit}"
if [ $? -ne 0 ]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to enable and start Gunicorn socket for ${environment}."
    exit 1
fi

echo -e "\e[38;5;72m[INFO]\e[0m Gunicorn socket for ${environment} started successfully."
echo -e "\e[38;5;72m[INFO]\e[0m The Gunicorn service will start automatically upon the first connection."