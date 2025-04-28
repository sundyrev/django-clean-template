#!/bin/bash
set -e

# Function to display usage information
usage() {
    echo "Usage: $0 [--project PROJECT_NAME] [--dev]"
    echo "  --project  Project name. If not specified, it will be prompted from the user."
    echo "  --dev     Copy files without minification (development mode)."
    exit 1
}

# Initialize variables
project_name=""
mode="minify"

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
        --dev)
            mode="copy"
            shift
            ;;
        *)
            echo -e "\e[38;5;196m[ERROR]\e[0m Unknown parameter: $1"
            usage
            ;;
    esac
done

# Prompt for project name if not provided
if [[ -z "${project_name}" ]]; then
    read -e -p $'\e[38;5;117m[INPUT]\e[0m Project name: ' project_name
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
    read -e -p $'\e[38;5;117m[INPUT]\e[0m Project path: ' project_path
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

# Check if virtual environment exists
if [[ ! -d "${project_path}/env" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Virtual environment not found at \e[38;5;223m${project_path}/env\e[0m."
    exit 1
fi

# Check if static directory exists
static_path="${project_path}/${project_name}/static"
if [[ ! -d "$static_path" ]]; then
    echo -e "\e[38;5;196m[ERROR]\e[0m Static directory not found at \e[38;5;223m$static_path\e[0m."
    exit 1
fi

# Check if esbuild is installed, install if missing
if ! command -v esbuild >/dev/null 2>&1; then
    echo -e "\e[38;5;72m[INFO]\e[0m esbuild not found, installing..."
    curl -fsSL https://esbuild.github.io/dl/latest | sh
    sudo mv esbuild /usr/local/bin/esbuild
    sudo chmod +x /usr/local/bin/esbuild
    if ! command -v esbuild >/dev/null 2>&1; then
        echo -e "\e[38;5;196m[ERROR]\e[0m Failed to install esbuild."
        exit 1
    fi
    echo -e "\e[38;5;72m[INFO]\e[0m esbuild installed successfully."
fi

# Ensure ${project_path}/${project_name}/static/dist exists with correct permissions
dist_path="${project_path}/${project_name}/static/dist"
if [ ! -d "$dist_path" ]; then
    echo -e "\e[38;5;72m[INFO]\e[0m Creating $dist_path..."
    sudo mkdir -m 755 -p "$dist_path"
    sudo chown www-data:www-data "$dist_path"
    sudo chmod 775 "$dist_path"
fi

# Process .js and .css files
echo -e "\e[38;5;72m[INFO]\e[0m Processing static files (mode: $mode)..."
find "${project_path}/${project_name}/static" -type f \( -name "*.js" -o -name "*.css" \) ! -path "${project_path}/${project_name}/static/dist/*" -exec sh -c '
    infile="$1"
    # Compute relative path from static/ and prepend dist/
    relative_path=$(echo "$1" | sed "s|${3}/${2}/static/||")
    outfile="${3}/${2}/static/dist/$relative_path"
    mkdir -p "$(dirname "$outfile")"
    if [ "$4" = "copy" ]; then
        cp "$infile" "$outfile" 2>/dev/null
    else
        esbuild "$infile" --minify --drop:console --outfile="$outfile"
    fi
    sudo chown www-data:www-data "$outfile"
    sudo chmod 664 "$outfile"
' _ {} "$project_name" "$project_path" "$mode" \;

echo -e "\e[38;5;48m[SUCCESS]\e[0m Static files processed successfully."