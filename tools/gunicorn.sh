#!/bin/bash
set -e

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

# Expand ~ in project_path if it comes from environment variable
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

echo -e "\e[38;5;72m[INFO]\e[0m Starting Gunicorn..."
if systemctl list-unit-files | grep -q "${project_name}.gunicorn.service"; then
    sudo systemctl start "${project_name}.gunicorn.service"
    if [ $? -ne 0 ]; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to start Gunicorn service."
        exit 1
    fi
    if ! sudo systemctl is-active "${project_name}.gunicorn.service" > /dev/null; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn service failed to activate."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m Gunicorn service started successfully."
else
    echo -e "\e[38;5;196m[ERROR]\e[0m Gunicorn service '${project_name}.gunicorn.service' not found."
    exit 1
fi