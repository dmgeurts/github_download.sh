#!/bin/bash
# Script for downloading GitHub hosted code
# Initially written for downloading gnmic

## Usage info
show_help() {
cat << EOF
Usage: ${0##*/} [-h] -o OWNER [OPTIONS] REPO
This script downloads files from a given GitHub repository.

    REPO        Name of the GitHub repository to download from.
    -o OWNER    Name of the owner of the repository.
    -a ARCH     Architectures to download (regex):
                'x86_64', 'aarch64' or '(amd|x86_)64' (default) to fetch multiple.
    -b BUILD    OS or distro, defaults to 'Linux' (regex):
                Example for sudo: (ubu2[02]04|el8)
    -t TYPE     Type of files to download (regex, no square brackets):
                'deb', 'tar.gz' or '(deb|rpm)' (default) to fetch multiple.
    -p PATH     Location to download files to.
                Defaults to '/var/www/tech/sw/\$repo'.
    -k <nr>     Number of files to keep, default: 5.
    -r          Create repo data files, default: no.

    -h          Display this help and exit.
EOF
}

## Fixed variables
#owner="openconfig"
#repo="gnmic"
arch="(amd|x86_)64"
type="(deb|rpm)"
build="Linux"
keep=5
make_repo="n"
base="/var/www/tech/sw"

## Read/interpret optional arguments
while getopts o:a:b:t:p:k:rh opt; do
    case $opt in
        o)  owner=$OPTARG
            ;;
        a)  arch=$OPTARG
            ;;
        b)  build=$OPTARG
            ;;
        t)  type=$OPTARG
            ;;
        p)  file_path=$OPTARG
            ;;
        k)  keep=$OPTARG
            ;;
        r)  make_repo="y"
            ;;
        h)  show_help
            exit 0
            ;;
        *)  show_help >&2
            exit 1
            ;;
    esac
done
shift "$((OPTIND-1))"   # Discard the options and sentinel --

# Check if the required options were given
repo="$@"
if [[ -z "${repo//[[:space:]]/}" ]]; then
    printf 'ERROR: Missing repo name.\n\n'
    show_help >&2
    exit 1
fi
if [[ -z $owner ]]; then
    printf 'ERROR: Missing -o, a repo owner must be given.\n\n'
    show_help >&2
    exit 1
fi
# Use the default path if none are given
file_path=${file_path:-"$base/$repo"}
if [[ ! -d "$file_path" ]]; then
    printf 'ERROR: Path does not exist, please create: %s\n\n' "$file_path"
    exit 1
fi
printf 'Using - Arch(s): %s, Build: %s, File type(s): %s & Path: %s\n' "$arch" "$build" "$type" "$file_path"

#echo "Fetching latest version."
latest_ver="$(curl -s https://api.github.com/repos/$owner/$repo/releases/latest |
    jq '.name' | sed -e 's/\"//g' | sed 's/^[^[:digit:]]*//')"
printf 'Latest version found: %s\n' "$latest_ver"
tag_name="$(curl -s https://api.github.com/repos/$owner/$repo/releases/latest |
    jq '.tag_name' | sed -e 's/\"//g')"
downloads="$(curl -s https://api.github.com/repos/$owner/$repo/releases/latest |
    jq '.assets[].browser_download_url' | awk "/$build/ && /$arch/ && /\.$type\"$/" | sed -e 's/\"//g')"
echo "Found $(echo "$downloads" | wc -l) files to download."
arch_found="$(awk -F / '{print $NF}' <<< "$downloads" | sed 's/\.[^.]*$//' | sed -E "s/.*$arch[\.-_]//" | sort -u)"

# Fetch missing files
declare -a fetched=()
for url in $downloads
do
    file="$(basename $url)"
    ext="$(awk -F. '!a[$NF]++{print $NF}' <<< "$file")"
    dist="$([[ "$file" =~ ($build) ]] && echo "${BASH_REMATCH[1]}")"
    if [[ "$ext" == "gz" ]]; then
        # Don't store in (tar.)gz folder, but instead use the build (dist) of the file.
        ext="$dist"
    fi
    # Test if this file needs to be downloaded
    if ! find "$file_path/$ext/$file" -type f &>/dev/null; then
        printf 'Downloading: %s\n' "$file"
        if printf '%s\n' "$(curl --version | awk '{print $2}' RS="")" "7.73.0" | sort -C -V; then
            mkdir -p "$file_path/$ext/" && cd "$file_path/$ext/"
            curl -s -O -L "$url"
        else
            curl -s -f -O --output-dir "$file_path/$ext/" --create-dirs -L "$url"
        fi
        if [[ ! -s "$file_path/$ext/$file" ]] || grep -q "Not Found" "$file_path/$ext/$file" 2>/dev/null; then
            rm -f "$file_path/$ext/$file"
            echo "ERROR: download failed for $file."
        else
            fetched+=("$file_path/$ext/$file")
        fi
    fi
    # Cleanup old files
    find $file_path/ -type f -name "$(grep -o '^[^[:digit:]]*' <<< "$file")[0-9]*$dist*" |
        sort | head -n -$keep | xargs --no-run-if-empty rm
done

if [ ${#fetched[@]} -eq 0 ]; then
    printf 'No files downloaded.\n'
else
    if [[ "$make_repo" == "y" ]]; then
        for ext in $(sed 's/[()]//g' <<< "${type//|/ }")
        do
            if [[ "$ext" == "deb" ]]; then
                if [[ -n $(find "$file_path/$ext/" -mmin -30 -type f -name "*.deb") ]]; then
                    if command -v pulp-manifest >/dev/null 2>&1; then
                        if ! pulp-manifest "$file_path/$ext/"; then
                            echo " ERROR: pulp-manifest failed in $file_path/$ext/"
                        fi
                    else
                        echo " WARNING: pulp-manifest not found. Skipping manifest generation."
                    fi
                    if command -v dpkg-scanpackages >/dev/null 2>&1; then
                        # Ensure the target directory for the Release file exists
                        mkdir -p "$(dirname "$base/$repo/deb/Release")"
                        # Generate the APT Release file
                        if dpkg-scanpackages "$file_path/$ext/" /dev/null > "$base/$repo/deb/Release"; then
                            echo " $ext: APT Release file created successfully."
                        else
                            echo " ERROR: dpkg-scanpackages failed."
                            exit 1
                        fi
                    else
                        echo " ERROR: dpkg-dev is not installed (missing dpkg-scanpackages)."
                        exit 1
                    fi
                else
                    echo " No new $ext files found to index."
                fi
            elif [[ "$ext" == "rpm" ]]; then
                if [[ -n $(find "$file_path/$ext/" -mmin -30 -type f -name "*.rpm") ]]; then
                    # Check if the command exists before running it
                    if command -v createrepo_c >/dev/null 2>&1; then
                        if createrepo_c --update "$file_path/$ext/"; then
                            echo " $ext: Yum repodata (re)created."
                        else
                            echo " ERROR: createrepo_c failed to update metadata in $file_path/$ext/"
                            exit 1
                        fi
                    else
                        echo " ERROR: createrepo_c is not installed. Install with 'sudo apt install createrepo-c'"
                        exit 1
                    fi
                else
                    echo " No new $ext files found to index."
                fi
            fi
        done
    fi
    echo 'New available files:'
    printf ' - %s\n' "${fetched[@]}"
fi
