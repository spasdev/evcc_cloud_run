#!/bin/sh
set -e

# --- Tailscale Initialization ---
# Start Tailscale daemon in the background
# --tun=userspace-networking is crucial for Cloud Run
# --socks5-server enables the SOCKS5 proxy
/app/tailscaled --tun=userspace-networking --socks5-server=localhost:1055 &

# Bring up the Tailscale interface
# TAILSCALE_AUTHKEY is an environment variable you must set in Cloud Run secrets
# --hostname provides a name for your Cloud Run instance on your Tailnet
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=cloudrun-evcc --accept-routes --accept-dns

echo "Tailscale started"

# Set ALL_PROXY for evcc binary
export ALL_PROXY=socks5://localhost:1055/

# --- Original evcc entrypoint.sh logic (now integrated) ---

# started as hassio addon
HASSIO_OPTIONSFILE=/data/options.json

if [ -f "${HASSIO_OPTIONSFILE}" ]; then
	CONFIG=$(grep -o '"config_file": "[^"]*' "${HASSIO_OPTIONSFILE}" | grep -o '[^"]*$')
	SQLITE_FILE=$(grep -o '"sqlite_file": "[^"]*' "${HASSIO_OPTIONSFILE}" | grep -o '[^"]*$')

	# Config File Migration
	# If there is no config file found in '/config' we copy it from '/homeassistant' and rename the old config file to .migrated
	if [ ! -f "${CONFIG}" ]; then
		CONFIG_OLD=$(echo "${CONFIG}" | sed 's#^/config#/homeassistant#')
		if [ -f "${CONFIG_OLD}" ]; then
			mkdir -p "$(dirname "${CONFIG}")" && cp "${CONFIG_OLD}" "${CONFIG}"
			mv "${CONFIG_OLD}" "${CONFIG_OLD}.migrated"
			echo "Moving old config file '${CONFIG_OLD}' to new location '${CONFIG}', appending '.migrated' to old config file! Old file can safely be deleted by user."
		fi
	fi

	# Database File Migration (optional, in case it is in /config)
	# Only in case the user put her DB into the '/config' folder instead of default '/data' we will migrate it aswell
	if [ "${SQLITE_FILE#/config}" != "${SQLITE_FILE}" ] && [ ! -f "${SQLITE_FILE}" ]; then
		SQLITE_FILE_OLD=$(echo "${SQLITE_FILE}" | sed 's#^/config#/homeassistant#')
		if [ -f "${SQLITE_FILE_OLD}" ]; then
			mkdir -p "$(dirname "${SQLITE_FILE}")" && cp "${SQLITE_FILE_OLD}" "${SQLITE_FILE}"
			mv "${SQLITE_FILE_OLD}" "${SQLITE_FILE_OLD}.migrated"
			echo "Moving old db file '${SQLITE_FILE_OLD}' to new location '${SQLITE_FILE}', appending '.migrated' to old db file! Old file can safely be deleted by user."
		fi
	fi

	echo "Using config file: ${CONFIG}"
	if [ ! -f "${CONFIG}" ]; then
		echo "Config not found. Please create a config under ${CONFIG}."
		echo "For details see evcc documentation at https://github.com/evcc-io/evcc#readme."
        # Exit with error if config is missing and it's a hassio setup
        exit 1
	else
		if [ "${SQLITE_FILE}" ]; then
			echo "starting evcc: 'EVCC_DATABASE_DSN=${SQLITE_FILE} /usr/local/bin/evcc --config ${CONFIG}'"
			exec env EVCC_DATABASE_DSN="${SQLITE_FILE}" /usr/local/bin/evcc --config "${CONFIG}"
		else
			echo "starting evcc: '/usr/local/bin/evcc --config ${CONFIG}'"
			exec /usr/local/bin/evcc --config "${CONFIG}"
		fi
	fi
else
    # This branch is for non-Hass.io addon usage.
    # It passes through command line arguments to evcc directly.
    # We will ensure evcc is called with the full path.

    # Check if the first argument is 'evcc' or starts with '-' (like a flag)
	if [ "$1" = 'evcc' ]; then
		shift # Remove 'evcc' from arguments if it's the first arg
		exec /usr/local/bin/evcc "$@"
	elif expr "$1" : '-.*' > /dev/null; then
        # If the first argument is a flag, assume it's directly for evcc
		exec /usr/local/bin/evcc "$@"
	else
        # If no specific evcc arguments, just execute the default command,
        # which should be evcc by itself, or whatever the user intends.
        # This part assumes a default usage similar to the original Docker CMD.
        # Given your Dockerfile has CMD [ "evcc" ], this would run evcc.
		exec /usr/local/bin/evcc "$@" # Ensure full path to evcc
	fi
fi
