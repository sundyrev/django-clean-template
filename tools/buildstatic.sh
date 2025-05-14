#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Script to build and collect static files
# ============================================
# This script finds all JS and CSS files under the project static
# directories (global and per-app), minifies them into the dist directory,
# and runs Django's collectstatic.

# Usage: buildstatic.sh [--project PROJECT_NAME]
#   --project PROJECT_NAME: Name of the Django project folder

# Function to display usage information
usage() {
    printf "Usage: %s [--project PROJECT_NAME]\n" "$0"
    printf "  --project  Project name. If not specified, it will be prompted from the user.\n"
    exit 1
}

project_name=""

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --project)
            project_name="${2:-}"
            if [[ -z "$project_name" || "$project_name" == --* ]]; then
                printf "\033[38;5;196m[ERROR]\033[0m --project requires a value\n" >&2
                exit 1
            fi
            shift 2
            ;;
        -*|--*)
            printf "\033[38;5;196m[ERROR]\033[0m Unknown option: %s\n" "$1" >&2
            usage
            ;;
        *)
            shift
            ;;
    esac
done

# Prompt for project name if not provided
if [[ -z "$project_name" ]]; then
    read -rp "Project name: " project_name
    if [[ -z "$project_name" ]]; then
        printf "\033[38;5;196m[ERROR]\033[0m Project name is required.\n" >&2
        exit 1
    fi
fi

# Resolve project_path from environment variable or prompt
project_path_var="${project_name^^}_PATH"
project_path="${!project_path_var:-}"
if [[ -n "$project_path" ]]; then
    project_path="${project_path/#\~/$HOME}"
fi
if [[ -z "$project_path" ]]; then
    read -erp "Project path: " project_path
    project_path="${project_path/#\~/$HOME}"
    project_path=$(realpath -m "$project_path")
fi

# Validate project_path
if [[ -z "${project_path}" ]]; then
    printf "\033[38;5;196m[ERROR]\033[0m Project path is required.\n"
    exit 1
fi

if [[ ! -d "${project_path}" ]]; then
    printf "\033[38;5;196m[ERROR]\033[0m Project directory not found at \033[38;5;223m%s\033[0m.\n" "${project_path}"
    exit 1
fi

# Check if virtual environment exists
if [[ ! -d "${project_path}/env" ]]; then
    printf "\033[38;5;196m[ERROR]\033[0m Virtual environment not found at \033[38;5;223m%s/env\033[0m.\n" "${project_path}"
    exit 1
fi

# Ensure dist directory exists with correct permissions
dist_path="${project_path}/${project_name}/dist"
if [ ! -d "$dist_path" ]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Creating $dist_path..."
    sudo mkdir -m 755 -p "$dist_path"
    sudo chown www-data:www-data "$dist_path"
    sudo chmod 775 "$dist_path"
else
    echo -e "\e[38;5;72m[INFO]\e[0m Cleaning existing $dist_path..."
    sudo rm -rf "${dist_path:?}/"*
fi

# Check write permissions for dist directory
if ! sudo -u www-data test -w "$dist_path"; then
    echo -e "\e[38;5;196m[ERROR]\e[0m No write permissions for $dist_path."
    exit 1
fi

# Check if esbuild is installed, install if missing
if ! command -v esbuild >/dev/null 2>&1; then
    printf "\033[38;5;72m[INFO]\033[0m esbuild not found, installing...\n"
    curl -fsSL https://esbuild.github.io/dl/latest | sh
    sudo mv esbuild /usr/local/bin/esbuild
    sudo chmod +x /usr/local/bin/esbuild
    if ! command -v esbuild >/dev/null 2>&1; then
        printf "\033[38;5;196m[ERROR]\033[0m Failed to install esbuild.\n"
        exit 1
    fi
    printf "\033[38;5;72m[INFO]\033[0m esbuild installed successfully.\n"
fi

# Function to process files: JS and CSS
process_dir() {
    local src="$1"
    find "$src" -type f \( -name "*.js" -o -name "*.css" \) | while read -r infile; do
        rel="${infile#"$src"/}"              # e.g. recaptcha/js/recaptcha-handler.js
        ext="${rel##*.}"                     # js или css
        base="${rel%.*}"                     # recaptcha/js/recaptcha-handler
        outfile="${dist_path}/${base}.${ext}"
        mkdir -p "$(dirname "$outfile")"
        if [[ "$ext" == "js" ]]; then
            esbuild "$infile" --minify --drop:console --outfile="$outfile"
        else
            esbuild "$infile" --minify --outfile="$outfile"
        fi
        if [ $? -ne 0 ]; then
            printf "\033[38;5;196m[ERROR]\033[0m Failed to process %s\n" "$infile"
            exit 1
        fi
        printf "\033[38;5;33m[INFO]\033[0m Processed %s → %s\n" "$rel" "${base}.${ext}"
    done
}

# Collect all static source directories
global_static="${project_path}/${project_name}/static"
if [[ -d "$global_static" ]]; then
    process_dir "$global_static"
fi
apps_root="${project_path}/${project_name}/apps"
if [[ -d "$apps_root" ]]; then
    find "$apps_root" -type d -name static | while read -r app_static; do
        process_dir "$app_static"
    done
fi

export DJANGO_SETTINGS_MODULE=config.settings.production

# Activate virtualenv and collectstatic
source "${project_path}/env/bin/activate"
python "${project_path}/${project_name}/manage.py" collectstatic --no-input --clear || {
    echo -e "\e[38;5;196m[ERROR]\e[0m Failed to collect static files."
    exit 1
}
printf "\033[38;5;48m[SUCCESS]\033[0m Static files processed successfully.\n"