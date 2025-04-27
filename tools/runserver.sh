#!/bin/bash
set -e

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

echo -e "\e[38;5;72m[INFO]\e[0m Stopping Gunicorn..."
if systemctl list-unit-files | grep -q "${project_name}.gunicorn.socket"; then
    if systemctl --quiet is-active "${project_name}.gunicorn.socket"; then
        sudo systemctl stop "${project_name}.gunicorn.socket"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Gunicorn socket."
            exit 1
        fi
        echo -e "\e[38;5;72m[INFO]\e[0m Gunicorn socket stopped."
    else
        echo -e "\e[38;5;208m[WARNING]\e[0m Gunicorn socket is not active, skipping stop."
    fi
fi

if systemctl list-unit-files | grep -q "${project_name}.gunicorn.service"; then
    if systemctl --quiet is-active "${project_name}.gunicorn.service"; then
        sudo systemctl stop "${project_name}.gunicorn.service"
        if [ $? -ne 0 ]; then
            echo -e "\e[38;5;196m[ERROR]\e[0m Failed to stop Gunicorn service."
            exit 1
        fi
        echo -e "\e[38;5;72m[INFO]\e[0m Gunicorn service stopped."
    else
        echo -e "\e[38;5;208m[WARNING]\e[0m Gunicorn service is not active, skipping stop."
    fi
else
    echo -e "\e[38;5;208m[WARNING]\e[0m Gunicorn service '${project_name}.gunicorn.service' not found, skipping stop."
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

export DJANGO_SETTINGS_MODULE=config.settings.local

echo -e "\e[38;5;72m[INFO]\e[0m Running Django development server..."
if [[ -f "${project_path}/${project_name}/manage.py" ]]; then
    python "${project_path}/${project_name}/manage.py" runserver 0.0.0.0:8000
else
    echo -e "\e[38;5;196m[ERROR]\e[0m manage.py not found at \e[38;5;223m${project_path}/${project_name}/manage.py\e[0m."
    exit 1
fi