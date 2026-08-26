#!/bin/bash

##################################################################################
# Script Name: fixEarnAppCerts.sh                                                #
# Description: Repairs EarnApp registration failures on native Linux installs.   #
#                                                                                #
# EarnApp nodes frequently refuse to link with                                   #
#                                                                                #
#   Failed registration: check internet connection and try again                 #
#                                                                                #
# on machines whose internet is perfectly fine. The earnapp binary is a bundled  #
# Node application, and it does not consult the operating system certificate     #
# store unless NODE_EXTRA_CA_CERTS points at it. Certificate verification fails, #
# and the binary reports that as a connectivity problem.                         #
#                                                                                #
# Installing ca-certificates alone does not fix this. The environment variable   #
# is the operative half.                                                        #
#                                                                                #
# This script refreshes the certificate store and adds the variable to the       #
# earnapp systemd service as a drop-in, so the packaged unit file is left        #
# untouched and an EarnApp update cannot silently undo the fix.                  #
#                                                                                #
# Containers do not need this script. EAincome's own image sets the variable at  #
# build time, and prebuilt images receive it on the docker run command line.     #
##################################################################################

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NOCOLOUR="\033[0m"

service_name="earnapp.service"
dropin_dir="/etc/systemd/system/earnapp.service.d"
dropin_file="$dropin_dir/override.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}This script needs root to edit the service and the certificate store.${NOCOLOUR}"
  echo -e "Run it as:\n"
  echo -e "${YELLOW}sudo bash fixEarnAppCerts.sh${NOCOLOUR}\n"
  exit 1
fi

if ! command -v earnapp >/dev/null 2>&1; then
  echo -e "${RED}The earnapp binary was not found on this system.${NOCOLOUR}"
  echo -e "${RED}This script fixes an existing native installation. To install EarnApp:${NOCOLOUR}\n"
  echo -e "${YELLOW}wget -qO /tmp/earnapp.sh https://brightdata.com/static/earnapp/install.sh${NOCOLOUR}"
  echo -e "${YELLOW}sudo bash /tmp/earnapp.sh${NOCOLOUR}\n"
  exit 1
fi

# 1. Refresh the certificate store. A store that is merely present is not enough
#    if it is years out of date, so reinstall rather than just install.
echo -e "${YELLOW}Refreshing the system certificate store..${NOCOLOUR}"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall ca-certificates openssl
  update-ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  dnf -y reinstall ca-certificates openssl || dnf -y install ca-certificates openssl
  update-ca-trust extract
elif command -v yum >/dev/null 2>&1; then
  yum -y reinstall ca-certificates openssl || yum -y install ca-certificates openssl
  update-ca-trust extract
elif command -v pacman >/dev/null 2>&1; then
  pacman -S --noconfirm ca-certificates openssl
  update-ca-trust extract 2>/dev/null || trust extract-compat
elif command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive install --force ca-certificates openssl
  update-ca-certificates
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache ca-certificates openssl
  update-ca-certificates
else
  echo -e "${YELLOW}No supported package manager was found, so the certificate store${NOCOLOUR}"
  echo -e "${YELLOW}could not be refreshed automatically. Continuing with what is present.${NOCOLOUR}"
fi

# 2. Find the bundle. Distributions disagree on where this lives.
bundle=""
for candidate in /etc/ssl/certs/ca-certificates.crt \
                 /etc/pki/tls/certs/ca-bundle.crt \
                 /etc/ssl/ca-bundle.pem \
                 /etc/ssl/cert.pem; do
  if [ -s "$candidate" ]; then
    bundle=$(readlink -f "$candidate")
    break
  fi
done

if [ -z "$bundle" ]; then
  echo -e "${RED}No certificate bundle could be found in any of the usual locations.${NOCOLOUR}"
  echo -e "${RED}Install your distribution's ca-certificates package and run this again.${NOCOLOUR}"
  exit 1
fi

cert_count=$(grep -c 'BEGIN CERTIFICATE' "$bundle" 2>/dev/null || echo '?')
echo -e "${GREEN}Certificate bundle: $bundle ($cert_count certificates)${NOCOLOUR}"

# 3. Install the drop-in. A drop-in is used rather than editing the unit file so
#    that reinstalling or updating EarnApp does not discard the fix.
if ! command -v systemctl >/dev/null 2>&1; then
  echo -e "${YELLOW}systemd was not detected on this machine, so no service was changed.${NOCOLOUR}"
  echo -e "${YELLOW}Set the following in whatever supervises earnapp, then restart it:${NOCOLOUR}\n"
  echo -e "${YELLOW}NODE_EXTRA_CA_CERTS=$bundle${NOCOLOUR}\n"
  exit 0
fi

if ! systemctl cat "$service_name" >/dev/null 2>&1; then
  echo -e "${YELLOW}No $service_name unit exists on this machine.${NOCOLOUR}"
  echo -e "${YELLOW}If you run earnapp by hand, export the variable in the same shell:${NOCOLOUR}\n"
  echo -e "${YELLOW}export NODE_EXTRA_CA_CERTS=$bundle${NOCOLOUR}"
  echo -e "${YELLOW}earnapp register${NOCOLOUR}\n"
  exit 0
fi

echo -e "${YELLOW}Writing $dropin_file..${NOCOLOUR}"
mkdir -p "$dropin_dir"
cat > "$dropin_file" <<EOF
# Added by fixEarnAppCerts.sh from EAincome.
#
# The earnapp binary bundles its own Node runtime and ignores the system trust
# store unless this variable points at a certificate bundle. Without it,
# registration fails with "check internet connection and try again" even when
# the network is healthy.
[Service]
Environment="NODE_EXTRA_CA_CERTS=$bundle"
EOF

if [ ! -s "$dropin_file" ]; then
  echo -e "${RED}The drop-in file could not be written. Exiting..${NOCOLOUR}"
  exit 1
fi

systemctl daemon-reload

echo -e "${YELLOW}Restarting $service_name..${NOCOLOUR}"
systemctl restart "$service_name"
sleep 3

# 4. Confirm the variable actually reached the running service, rather than
#    assuming the drop-in was picked up.
if systemctl show "$service_name" --property=Environment | grep -q 'NODE_EXTRA_CA_CERTS'; then
  echo -e "${GREEN}NODE_EXTRA_CA_CERTS is now set on $service_name.${NOCOLOUR}"
else
  echo -e "${RED}The drop-in was written but systemd is not reporting the variable.${NOCOLOUR}"
  echo -e "${RED}Check the output of: systemctl cat $service_name${NOCOLOUR}"
  exit 1
fi

echo -e "${GREEN}========================================${NOCOLOUR}"
if [ -f /etc/earnapp/registered ]; then
  echo -e "${GREEN}This node is already registered. Nothing further is needed.${NOCOLOUR}"
else
  echo -e "${GREEN}Certificates are fixed. Now link the node:${NOCOLOUR}\n"
  echo -e "${YELLOW}sudo earnapp register${NOCOLOUR}\n"
  echo -e "${GREEN}Open the URL it prints, claim the node in your dashboard, then check:${NOCOLOUR}\n"
  echo -e "${YELLOW}sudo earnapp status${NOCOLOUR}"
fi
echo -e "${GREEN}========================================${NOCOLOUR}"

exit 0
