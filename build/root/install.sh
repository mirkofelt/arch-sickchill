#!/bin/bash

# exit script if return code != 0
set -e

# app name from buildx arg, used in healthcheck to identify app and monitor correct process
APPNAME="${1}"
shift

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1}"
shift

# target arch from buildx arg
TARGETARCH="${1}"
shift

if [[ -z "${APPNAME}" ]]; then
	echo "[warn] App name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# write APPNAME and RELEASETAG to file to record the app name and release tag used to build the image
echo -e "export APPNAME=${APPNAME}\nexport IMAGE_RELEASE_TAG=${RELEASETAG}\n" >> '/etc/image-build-info'

# ensure we have the latest builds scripts
refresh.sh

# pacman packages
####

# define pacman packages
pacman_packages="python python-pip"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# define aur packages
aur_packages=""

# call aur install script (arch user repo)
# The base image's aur.sh now exits with its usage text when it is handed no
# package, so calling it with an empty list is no longer the no-op it used to
# be. Guarded the same way the pacman block above is.
if [[ -n "${aur_packages}" ]]; then
	source aur.sh
fi

# github
####

install_path="/opt/sickchill"
mkdir -p "${install_path}"

# download sickchill from branch 'master'
# '--depth=1' ensures only latest commits to speed up download
git clone --depth=1 --branch master https://github.com/SickChill/sickchill "${install_path}"

# python
####

mkdir -p "${install_path}"

# The upstream recipe asked python.sh to install from '<install_path>/requirements.txt'.
# SickChill dropped requirements.txt in 2021 and has shipped a Poetry project
# (pyproject.toml) ever since, so that path has never existed for the cloned tree.
# The base image's python.sh used to shrug that off; it now calls a missing
# requirements.txt fatal, which is what stopped this build.
#
# Installing the cloned working tree via --pip-packages keeps the original intent
# (SickChill's master branch, resolved at build time) and uses the same helper
# option binhex used before the clone was introduced. It is also what produces
# '<install_path>/bin/sickchill' - the console script declared in pyproject's
# [project.scripts] that run/nobody/start.sh invokes, and the one the published
# upstream image contains.
#
# Note: --pip-packages 'sickchill' (the pre-clone form) is not an option here.
# The PyPI release is frozen at 2024.3.1 and predates the TheTVDB v4 indexer.
python.sh --create-pyenv 'no' --create-virtualenv 'yes' --pip-packages "${install_path}" --virtualenv-path "${install_path}"

# container perms
####

# define comma separated list of paths
install_paths="/home/nobody,${install_path}"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

# cleanup
cleanup.sh
