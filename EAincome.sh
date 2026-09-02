#!/bin/bash

##################################################################################
# Script Name: EAincome (EarnApp focused, supports proxies)                      #
# Description: Runs EarnApp nodes in Docker, optionally one per proxy.           #
#                                                                               #
# This is an EarnApp-only variant of Internet Income by engageub.                #
# Upstream: https://github.com/engageub/InternetIncome                           #
#                                                                               #
# DISCLAIMER: This script is provided "as is" and without warranty of any kind.  #
# The authors make no warranties, express or implied, that this script is free   #
# of errors, defects, or suitable for any particular purpose. The authors shall  #
# not be liable for any damages suffered by any user of this script, whether     #
# direct, indirect, incidental, consequential, or special, arising from the use  #
# of or inability to use this script or its documentation.                       #
##################################################################################

######### DO NOT EDIT THE CODE BELOW UNLESS YOU KNOW WHAT YOU ARE DOING  #########
# Colours
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NOCOLOUR="\033[0m"

# Script name, used in help and error messages
script_name="EAincome.sh"

# File names
properties_file="properties.conf"
banner_file="banner.jpg"
proxies_file="proxies.txt"
container_names_file="containernames.txt"
earnapp_file="earnapp.txt"
earnapp_data_folder="earnappdata"
networks_file="networks.txt"
restart_file="restart.sh"
dns_resolver_file="resolv.conf"
process_id_file="process.pid"
required_files=($banner_file $properties_file $restart_file)
files_to_be_removed=($dns_resolver_file $container_names_file $networks_file $process_id_file)
folders_to_be_removed=($earnapp_data_folder)
back_up_folders=()
back_up_files=($earnapp_file)
container_pulled=false
docker_in_docker_detected=false

# Image used for Docker-in-Docker filesystem checks
docker_cli_image="docker:cli"

# Local image build context
docker_folder="docker"
dockerfile_path="$docker_folder/Dockerfile"
docker_entrypoint_path="$docker_folder/entrypoint.sh"

# Set by resolve_earnapp_image
earnapp_image_is_local=false
earnapp_ca_params=""

# Set from EARNAPP_DEBUG in properties.conf. Turns on Node's own debug channels
# inside the container, which is the only way to get the earnapp binary to print
# anything: 'earnapp run' is silent, and only the registration phase talks.
earnapp_debug_params=""

#Unique Id
UNIQUE_ID=`cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | dd bs=1 count=32 2>/dev/null`

# Use banner if exists
if [ -f "$banner_file" ]; then
  for _ in {1..3}; do
    for color in "${RED}" "${GREEN}" "${YELLOW}"; do
      clear
      echo -e "$color"
      cat "$banner_file"
      sleep 0.5
    done
  done
  echo -e "${NOCOLOUR}"
fi

format_duration() {
  local seconds=$1
  local mins=$((seconds / 60))
  local secs=$((seconds % 60))

  if (( mins > 0 )); then
    echo "${mins} min ${secs} sec"
  else
    echo "${secs} sec"
  fi
}

# Read properties.conf and export every key as a shell variable.
# Factored out of --start so that --build can read the same configuration.
load_properties() {
  if [ ! -f "$properties_file" ]; then
    echo -e "${RED}Required file $properties_file does not exist, exiting..${NOCOLOUR}"
    exit 1
  fi

  # Remove special characters ^M from properties file
  sed -i 's/\r//g' "$properties_file"

  while IFS= read -r line; do
    # Ignore lines that start with #
    if [[ $line != '#'* ]]; then
        # Split the line at the first occurrence of =
        key="${line%%=*}"
        value="${line#*=}"
        # Trim leading and trailing whitespace from key and value
        key="${key%"${key##*[![:space:]]}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # Ignore lines without a value after =
        if [[ -n $value ]]; then
            # Replace variables with their values
            value=$(eval "echo $value")
            # Export the key-value pairs as variables
            export "$key"="$value"
        fi
    fi
  done < "$properties_file"
}

# Check if a container with the given name already exists.
# Usage: check_container_exists <name> [prefix] [image]
# When a prefix is supplied, any existing direct-connection (bridge network)
# container matching that prefix and image is removed first, so that a rerun
# does not leave two nodes sharing one IP.
check_container_exists() {
  local container_name="$1"
  local prefix="$2"
  local image="$3"
  # Validate input
  if [ -z "$container_name" ]; then
    echo -e "${RED}Error: container_name is required. Exiting..${NOCOLOUR}"
    exit 1
  fi
  # Check if container exists
  if sudo docker inspect --type container "$container_name" >/dev/null 2>&1; then
    echo -e "${RED}A container with name $container_name already exists. Exiting..${NOCOLOUR}"
    exit 1
  fi
  # If prefix is provided, find and delete any existing direct-connection containers
  if [ -n "$prefix" ]; then
    while IFS= read -r cname; do
      [[ -z "$cname" ]] && continue
      # Extract trailing hex run - exactly 32 chars means direct mode (no proxy index appended)
      trailing=$(echo "$cname" | grep -oE '[a-f0-9]+$')
      if [ ${#trailing} -ne 32 ]; then
        continue
      fi
      # Inspect once and extract both network mode and image
      read -r network container_image <<< $(sudo docker inspect --type container "$cname" --format '{{.HostConfig.NetworkMode}} {{.Config.Image}}' 2>/dev/null)
      # Skip if network is not bridge
      if [ "$network" != "bridge" ]; then
        continue
      fi
      # If image parameter is provided, skip if image does not match
      if [ -n "$image" ] && [ "$container_image" != "$image" ]; then
        continue
      fi
      echo -e "${YELLOW}Existing direct-connection container found: $cname (Image: $container_image). Deleting..${NOCOLOUR}"
      sudo docker rm -f "$cname"
      echo -e "${GREEN}Deleted container $cname successfully.${NOCOLOUR}"
    done < <(sudo docker ps --format '{{.Names}}' | grep "^${prefix}")
  fi
  # Append container name to tracking file
  echo "$container_name" | tee -a "$container_names_file"
}

# Validate proxies format.
# All proxies are routed through tun2proxy, which supports http, https,
# socks4 and socks5 only. Shadowsocks (ss://) is rejected explicitly.
validate_proxies() {
  local lineno=0
  local proxy
  while IFS= read -r proxy || [[ -n "$proxy" ]]; do
    ((lineno++))
    [[ -z "$proxy" || "$proxy" == \#* ]] && continue
    local valid=false
    # Strip whitespace
    proxy=$(echo "$proxy" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Must have a protocol
    if echo "$proxy" | grep -qE "^[a-zA-Z0-9+-]+://"; then
      local protocol="${proxy%%://*}"
      protocol=$(echo "$protocol" | tr '[:upper:]' '[:lower:]')
      local rest="${proxy#*://}"

      # Shadowsocks is not supported by tun2proxy
      if [[ "$protocol" == "ss" ]]; then
        echo -e "${RED}Error: Unsupported proxy protocol 'ss' on line ${lineno}: '${proxy}'${NOCOLOUR}"
        echo -e "${RED}All proxies are routed through tun2proxy, which supports http, https, socks4 and socks5 only.${NOCOLOUR}"
        exit 1
      fi

      # Split on last @ to handle special chars (including @) in passwords
      local hostport credentials
      if echo "$rest" | grep -q "@"; then
        hostport="${rest##*@}"
        credentials="${rest%@*}"
      else
        hostport="$rest"
        credentials=""
      fi
      # Validate host:port
      if echo "$hostport" | grep -qE "^[a-zA-Z0-9._-]+:[0-9]{1,5}$"; then
        local port="${hostport##*:}"
        if (( port >= 1 && port <= 65535 )); then
          case "$protocol" in
            http|https|socks5)
              [[ -z "$credentials" ]] && valid=true
              if [[ -n "$credentials" ]]; then
                local user="${credentials%%:*}"
                local pass="${credentials#*:}"
                [[ -n "$user" && "$credentials" == *":"* && -n "$pass" ]] && valid=true
              fi
              ;;
            socks4)
              valid=true
              ;;
          esac
        fi
      fi
    fi
    if [[ "$valid" == false ]]; then
      echo -e "${RED}Error: Invalid proxy format on line ${lineno}: '${proxy}'${NOCOLOUR}"
      echo -e "${RED}Expected: protocol://host:port or protocol://user:password@IP:PORT${NOCOLOUR}"
      echo -e "${RED}Supported protocols: http, https, socks4, socks5${NOCOLOUR}"
      exit 1
    fi
  done < "$proxies_file"
}

# Resolve which DNS strategy tun2proxy should use.
# TUN2PROXY_DNS_MODE wins if set; otherwise it is derived from USE_DNS_OVER_HTTPS
# so that existing configurations keep working.
resolve_dns_mode() {
  if [[ -z "$TUN2PROXY_DNS_MODE" ]]; then
    if [ "$USE_DNS_OVER_HTTPS" = true ]; then
      TUN2PROXY_DNS_MODE="over-tcp"
    else
      TUN2PROXY_DNS_MODE="virtual"
    fi
  elif [[ "$USE_DNS_OVER_HTTPS" == true && "$TUN2PROXY_DNS_MODE" != "over-tcp" ]]; then
    echo -e "${YELLOW}Note: USE_DNS_OVER_HTTPS is true but TUN2PROXY_DNS_MODE is set to${NOCOLOUR}"
    echo -e "${YELLOW}'$TUN2PROXY_DNS_MODE', which takes precedence. Leave TUN2PROXY_DNS_MODE blank${NOCOLOUR}"
    echo -e "${YELLOW}if you want USE_DNS_OVER_HTTPS to select the DNS mode.${NOCOLOUR}"
  fi

  case "$TUN2PROXY_DNS_MODE" in
    virtual|over-tcp|direct) ;;
    *)
      echo -e "${RED}Invalid TUN2PROXY_DNS_MODE '$TUN2PROXY_DNS_MODE'. Exiting..${NOCOLOUR}"
      echo -e "${RED}Valid values are: virtual, over-tcp, direct${NOCOLOUR}"
      exit 1
      ;;
  esac

  if [ "$USE_SOCKS5_DNS" = true ]; then
    echo -e "${YELLOW}Note: USE_SOCKS5_DNS is deprecated and no longer selects a different proxy container.${NOCOLOUR}"
    echo -e "${YELLOW}All proxies now run through tun2proxy. To resolve DNS at the proxy over UDP,${NOCOLOUR}"
    echo -e "${YELLOW}set TUN2PROXY_DNS_MODE='direct' instead (requires a UDP capable proxy).${NOCOLOUR}"
  fi

  if [[ "$USE_PROXIES" == true ]]; then
    echo -e "${GREEN}tun2proxy DNS mode: $TUN2PROXY_DNS_MODE${NOCOLOUR}"
  fi
}

# Build EAincome's own EarnApp image from the docker folder.
#
# Building locally rather than pulling means every node on this host runs an
# identical, known-good binary with a trust store that is as fresh as the day you
# built it, instead of whatever a remote tag happens to point at today. The image
# is built once and then reused for every node UUID.
build_earnapp_image() {
  local tag="$1"

  if [ ! -f "$dockerfile_path" ] || [ ! -f "$docker_entrypoint_path" ]; then
    echo -e "${RED}Cannot build the EarnApp image because $dockerfile_path or${NOCOLOUR}"
    echo -e "${RED}$docker_entrypoint_path is missing.${NOCOLOUR}"
    echo -e "${RED}Restore the $docker_folder folder, or set BUILD_EARNAPP_IMAGE=false in${NOCOLOUR}"
    echo -e "${RED}$properties_file to use a prebuilt image instead. Exiting..${NOCOLOUR}"
    exit 1
  fi

  echo -e "${YELLOW}Building EarnApp image $tag.${NOCOLOUR}"
  echo -e "${YELLOW}This takes a few minutes the first time and is then cached.${NOCOLOUR}"

  # buildx is not installed everywhere. Fall back to the classic builder rather
  # than failing with "BuildKit is enabled but the buildx component is missing".
  local build_env=""
  if ! sudo docker buildx version >/dev/null 2>&1; then
    build_env="DOCKER_BUILDKIT=0"
  fi

  if sudo env $build_env docker build --pull -t "$tag" "$docker_folder"; then
    echo -e "${GREEN}Built $tag successfully.${NOCOLOUR}"
  else
    echo -e "${RED}Failed to build $tag. Exiting..${NOCOLOUR}"
    exit 1
  fi
}

# Decide which EarnApp image to run, and how to give it a usable TLS trust store.
#
# The earnapp binary is a bundled Node application. It ignores the operating
# system trust store unless NODE_EXTRA_CA_CERTS points at a bundle. Without it,
# registration fails with "check internet connection and try again" on hosts whose
# internet is perfectly fine, because what actually failed was certificate
# verification. EAincome's own image bakes the variable in. A prebuilt third party
# image almost certainly does not, so the host's trust store is bind-mounted in
# and the variable is set on the command line instead.
resolve_earnapp_image() {
  if [ "$BUILD_EARNAPP_IMAGE" = true ]; then
    EARNAPP_IMAGE="$EARNAPP_LOCAL_TAG"
    earnapp_image_is_local=true

    if sudo docker image inspect "$EARNAPP_IMAGE" >/dev/null 2>&1; then
      echo -e "${GREEN}Reusing the EarnApp image already built on this host: $EARNAPP_IMAGE${NOCOLOUR}"
      echo -e "${GREEN}To rebuild it, run:${NOCOLOUR} sudo bash $script_name --build"
    else
      build_earnapp_image "$EARNAPP_IMAGE"
    fi
    return
  fi

  echo -e "${YELLOW}BUILD_EARNAPP_IMAGE is false, using prebuilt image $EARNAPP_IMAGE${NOCOLOUR}"

  local bundle=""
  local candidate
  for candidate in /etc/ssl/certs/ca-certificates.crt \
                   /etc/pki/tls/certs/ca-bundle.crt \
                   /etc/ssl/ca-bundle.pem \
                   /etc/ssl/cert.pem; do
    if [ -s "$candidate" ]; then
      bundle=$(readlink -f "$candidate")
      break
    fi
  done

  if [[ -n "$bundle" ]]; then
    earnapp_ca_params="--mount type=bind,source=$bundle,target=/etc/ssl/certs/ca-certificates.crt,readonly -e NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt"
    echo -e "${GREEN}Sharing this host's TLS trust store with the container: $bundle${NOCOLOUR}"
  else
    echo -e "${YELLOW}No CA bundle was found on this host, so nodes may fail to register${NOCOLOUR}"
    echo -e "${YELLOW}with 'check internet connection and try again'. That message means a${NOCOLOUR}"
    echo -e "${YELLOW}certificate failure, not a network one. Install the ca-certificates${NOCOLOUR}"
    echo -e "${YELLOW}package, or leave BUILD_EARNAPP_IMAGE=true so that EAincome builds an${NOCOLOUR}"
    echo -e "${YELLOW}image with a trust store of its own.${NOCOLOUR}"
  fi
}

# Start all containers
start_containers() {

  local i=$1
  local proxy=$2
  local DNS_VOLUME="--mount type=bind,source=$PWD/$dns_resolver_file,target=/etc/resolv.conf,readonly"

  if [ "$container_pulled" = false ]; then
    # For users with Docker-in-Docker, the PWD path is on the host where Docker is installed.
    # The files are created in the same path as the inner Docker path.
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 9.9.9.9\n' > $dns_resolver_file;
    if [ ! -f $dns_resolver_file ]; then
      echo -e "${RED}There is a problem creating resolver file. Exiting..${NOCOLOUR}";
      exit 1;
    fi
    sudo docker pull $docker_cli_image
    if sudo docker run --rm --mount type=bind,source=$PWD,target=/output $docker_cli_image sh -c "if [ ! -f /output/$dns_resolver_file ]; then exit 0; else exit 1; fi"; then
      docker_in_docker_detected=true
    fi
    sudo docker run --rm --mount type=bind,source=$PWD,target=/output $docker_cli_image sh -c "if [ ! -f /output/$dns_resolver_file ]; then printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 9.9.9.9\n' > /output/$dns_resolver_file; printf 'Docker-in-Docker is detected. The script runs with limited features.\nThe files and folders are created in the same path on the host where your parent docker is installed.\n'; fi"
  fi

  if [[ "$ENABLE_LOGS" != true ]]; then
    LOGS_PARAM="--log-driver none"
    TUN_LOG_PARAM="off"
  else
    # Upstream uses max-size=100k, and because max-file defaults to 1 that holds
    # only a couple of minutes of a busy node's output -- so by the time you go
    # looking, whatever you wanted to see has already been truncated away.
    # 10m x 3 keeps roughly a day per container and is still bounded.
    LOGS_PARAM="--log-driver=json-file --log-opt max-size=${LOG_MAX_SIZE:-10m} --log-opt max-file=${LOG_MAX_FILES:-3}"
    # Upstream uses trace here. tun2proxy at trace logs every connection it
    # relays, which costs CPU on every node and buries the EarnApp side of the
    # picture; info still shows tunnel setup and failures.
    TUN_LOG_PARAM="${TUN2PROXY_LOG_LEVEL:-info}"
  fi

  # Node's debug channels, off unless asked for. Worth knowing before enabling it:
  # this only affects the registration phase, because 'earnapp run' prints nothing
  # whatever you set. The output includes request headers and the node UUID, so
  # the log becomes account-identifying.
  if [[ "${EARNAPP_DEBUG:-false}" == true ]]; then
    earnapp_debug_params="-e EARNAPP_DEBUG=1"
    if [[ "$ENABLE_LOGS" != true && "$container_pulled" == false ]]; then
      echo -e "${RED}EARNAPP_DEBUG is on but ENABLE_LOGS is false, so the output is discarded. Set ENABLE_LOGS=true.${NOCOLOUR}"
    fi
  fi

  # Starting tun2proxy container
  if [[ $i && $proxy ]]; then
    NETWORK_TUN="--network=container:tun$UNIQUE_ID$i"

    echo -e "${YELLOW}Starting Proxy container..${NOCOLOUR}"
    if [ "$container_pulled" = false ]; then
      sudo docker pull "$TUN2PROXY_IMAGE"
    fi

    check_container_exists tun$UNIQUE_ID$i
    if CONTAINER_ID=$(sudo docker run --name tun$UNIQUE_ID$i $LOGS_PARAM --restart=always --mount type=bind,source=/dev/net/tun,target=/dev/net/tun --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 --cap-add=NET_ADMIN -d "$TUN2PROXY_IMAGE" --dns "$TUN2PROXY_DNS_MODE" --proxy "$proxy" --verbosity "$TUN_LOG_PARAM"); then
      echo -e "${GREEN}Container tun$UNIQUE_ID$i started successfully.${NOCOLOUR}"
    else
      echo -e "${RED}Failed to start container for proxy. Exiting..${NOCOLOUR}"
      exit 1
    fi
    sleep 1
  fi

  # Starting Earnapp container
  if [ "$EARNAPP" = true ]; then
    echo -e "${YELLOW}Starting Earnapp container..${NOCOLOUR}"
    echo -e "${GREEN}Copy the following node url and paste in your earnapp dashboard${NOCOLOUR}"
    echo -e "${GREEN}You will also find the urls in the file $earnapp_file in the same folder${NOCOLOUR}"
    for loop_count in {1..500}; do
      if [ "$loop_count" -eq 500 ]; then
        echo -e "${RED}Unique UUID cannot be generated for Earnapp. Exiting..${NOCOLOUR}"
        exit 1
      fi
      RANDOM_ID=`cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | dd bs=1 count=32 2>/dev/null`
      if [ -f $earnapp_file ]; then
        if ! grep -qF "$RANDOM_ID" "$earnapp_file"; then
          break
        fi
      else
        break;
      fi
    done
    date_time=`date "+%D %T"`
    # A locally built image has no registry to pull from.
    if [[ "$container_pulled" == false && "$earnapp_image_is_local" != true ]]; then
      sudo docker pull "$EARNAPP_IMAGE"
    fi
    mkdir -p $PWD/$earnapp_data_folder/data$i
    sudo chmod -R 777 $PWD/$earnapp_data_folder/data$i
    if [ -f $earnapp_file ] && uuid=$(sed "${i}q;d" $earnapp_file | grep -o 'https[^[:space:]]*'| sed 's/https:\/\/earnapp.com\/r\///g');then
      if [[ $uuid ]];then
        echo $uuid
      else
        echo "UUID does not exist, creating UUID"
        uuid=sdk-node-$RANDOM_ID
        printf "$date_time https://earnapp.com/r/%s\n" "$uuid" | tee -a $earnapp_file
      fi
    else
      echo "UUID does not exist, creating UUID"
      uuid=sdk-node-$RANDOM_ID
      printf "$date_time https://earnapp.com/r/%s\n" "$uuid" | tee -a $earnapp_file
    fi

    check_container_exists earnapp$UNIQUE_ID$i
    if CONTAINER_ID=$(sudo docker run -d --health-interval=24h --name earnapp$UNIQUE_ID$i $LOGS_PARAM $DNS_VOLUME --restart=always $NETWORK_TUN --mount type=bind,source=$PWD/$earnapp_data_folder/data$i,target=/etc/earnapp $earnapp_ca_params $earnapp_debug_params -e EARNAPP_UUID=$uuid "$EARNAPP_IMAGE"); then
      echo -e "${GREEN}Container earnapp$UNIQUE_ID$i started successfully.${NOCOLOUR}"
    else
      echo -e "${RED}Failed to start container for Earnapp. Exiting..${NOCOLOUR}"
      exit 1
    fi
  else
    if [[ "$container_pulled" == false && "$ENABLE_LOGS" == true ]]; then
      echo -e "${RED}Earnapp is not enabled. Ignoring Earnapp..${NOCOLOUR}"
    fi
  fi

  container_pulled=true
}

# Update and Install Docker
if [[ "$1" == "--install" ]]; then
  sudo apt-get update
  sudo apt-get -y install docker.io
  CPU_ARCH=`uname -m`
  if [ "$CPU_ARCH" == "aarch64" ] || [ "$CPU_ARCH" == "arm64" ]; then
    sudo docker run --privileged --rm tonistiigi/binfmt --install all
    sudo apt-get install qemu binfmt-support qemu-user-static
  fi
  # Check if Docker is installed
  if command -v docker &> /dev/null; then
    echo -e "${GREEN}Docker is installed.${NOCOLOUR}"
    docker --version
    exit 0
  else
    echo -e "${RED}Docker is not installed. There is a problem installing Docker.${NOCOLOUR}"
    echo "Please install Docker manually by following https://docs.docker.com/engine/install/"
    exit 1
  fi
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Docker is not installed, without which the script cannot start. Exiting..${NOCOLOUR}"
  echo -e "To install Docker and its dependencies, please run the following command\n"
  echo -e "${YELLOW}sudo bash $script_name --install${NOCOLOUR}\n"
  exit 1
fi

if [[ "$1" == "--start" ]]; then
  echo -e "\n\nStarting.."
  SCRIPT_START_TIME=$(date +%s)

  # Check if the required files are present
  for required_file in "${required_files[@]}"; do
    if [ ! -f "$required_file" ]; then
      echo -e "${RED}Required file $required_file does not exist, exiting..${NOCOLOUR}"
      exit 1
    fi
  done

  for file in "${files_to_be_removed[@]}"; do
    if [ -f "$file" ]; then
      echo -e "${RED}File $file still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash $script_name --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  for folder in "${folders_to_be_removed[@]}"; do
    if [ -d "$folder" ]; then
      echo -e "${RED}Folder $folder still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash $script_name --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  # Read the properties file and export variables to the current shell
  load_properties

  # CPU architecture to get docker images
  CPU_ARCH=`uname -m`

  # Write current PID to file
  echo "$$" > $process_id_file

  # Setting Device name
  if [[ ! $DEVICE_NAME ]]; then
    echo -e "${RED}Device Name is not configured. Using default name ${NOCOLOUR}ubuntu"
    DEVICE_NAME=ubuntu
  fi

  # Default images when not configured in properties.conf
  if [[ ! $TUN2PROXY_IMAGE ]]; then
    TUN2PROXY_IMAGE='ghcr.io/tun2proxy/tun2proxy:v0.8.3'
  fi

  if [[ ! $EARNAPP_IMAGE ]]; then
    EARNAPP_IMAGE='madereddy/earnapp:latest'
  fi

  # Tag used for the image EAincome builds itself
  if [[ ! $EARNAPP_LOCAL_TAG ]]; then
    EARNAPP_LOCAL_TAG='eaincome/earnapp:local'
  fi

  # Build locally by default. Set BUILD_EARNAPP_IMAGE=false in properties.conf to
  # pull EARNAPP_IMAGE from a registry instead.
  if [[ -z "$BUILD_EARNAPP_IMAGE" ]]; then
    BUILD_EARNAPP_IMAGE=true
  fi

  resolve_dns_mode

  if [ "$EARNAPP" = true ]; then
    resolve_earnapp_image
  fi

  if [ "$USE_PROXIES" = true ]; then
    echo -e "${GREEN}USE_PROXIES is enabled, using proxies..${NOCOLOUR}"
    if [ ! -f "$proxies_file" ]; then
      echo -e "${RED}Proxies file $proxies_file does not exist, exiting..${NOCOLOUR}"
      rm -f $process_id_file
      exit 1
    fi

    # Remove special character ^M and trim space from proxies file
    sed -i 's/\r//g' $proxies_file
    sed -i 's/^[ \t]*//;s/[ \t]*$//' $proxies_file
    # tun2proxy expects socks4 and socks5; normalise the remote-DNS aliases.
    # DNS is handled by tun2proxy itself, so the distinction is not needed.
    sed -i -E 's#^socks5h://#socks5://#; s#^socks4a://#socks4://#' $proxies_file
    validate_proxies
    i=0;
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[^#].* ]]; then
        i=`expr $i + 1`
        start_containers "$i" "$line"
      fi
    done < $proxies_file
  else
    echo -e "${RED}USE_PROXIES is disabled, using direct internet connection..${NOCOLOUR}"
    start_containers
  fi

  # Remove Process file
  rm -f $process_id_file

  SCRIPT_END_TIME=$(date +%s)
  TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

  echo -e "${GREEN}========================================${NOCOLOUR}"
  echo -e "${GREEN}All containers processed.${NOCOLOUR}"
  echo -e "${GREEN}Total runtime: $(format_duration $TOTAL_TIME)${NOCOLOUR}"
  echo -e "${GREEN}========================================${NOCOLOUR}"

  exit 0
fi

# Build the EarnApp image without starting any nodes
if [[ "$1" == "--build" ]]; then
  echo -e "\n\nBuilding the EarnApp image.."
  SCRIPT_START_TIME=$(date +%s)

  load_properties

  if [[ ! $EARNAPP_LOCAL_TAG ]]; then
    EARNAPP_LOCAL_TAG='eaincome/earnapp:local'
  fi

  build_earnapp_image "$EARNAPP_LOCAL_TAG"

  SCRIPT_END_TIME=$(date +%s)
  TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

  echo -e "${GREEN}========================================${NOCOLOUR}"
  echo -e "${GREEN}$EARNAPP_LOCAL_TAG is ready.${NOCOLOUR}"
  echo -e "${GREEN}Every node started with BUILD_EARNAPP_IMAGE=true will reuse it.${NOCOLOUR}"
  echo -e "${GREEN}Build runtime: $(format_duration $TOTAL_TIME)${NOCOLOUR}"
  echo -e "${GREEN}========================================${NOCOLOUR}"

  exit 0
fi

# Delete containers and networks
if [[ "$1" == "--delete" ]]; then
  echo -e "\n\nDeleting Containers and networks.."
  SCRIPT_START_TIME=$(date +%s)

  # Check if there is already a running process
  if [ -f "$process_id_file" ]; then
    PID=$(cat "$process_id_file")
    PROC_DIR=$(pwdx "$PID" 2>/dev/null | awk '{print $2}')
    if [ "$PROC_DIR" = "$PWD" ]; then
      echo "There is already a running process (PID $PID)."
      echo "Do you want to stop it and continue? (yes/no)"
      # Prompt with 60-second timeout
      read -r -t 60 ANSWER
      if [ $? -ne 0 ]; then
        echo "No response within 60 seconds. Exiting."
        exit 1
      fi
      case "$ANSWER" in
        yes|y|Y)
          echo "Stopping process $PID..."
          kill "$PID" 2>/dev/null
          sleep 2
          rm -f "$process_id_file"
          echo "Process stopped. Continuing..."
          ;;
        no|n|N)
          echo "Operation cancelled."
          exit 1
          ;;
        *)
          echo "Invalid response. Exiting."
          exit 1
          ;;
      esac
    fi
  fi

  # Delete containers by container names
  if [ -f "$container_names_file" ]; then
    for i in `cat $container_names_file`; do
      # Check if container exists
      if sudo docker inspect --type container $i >/dev/null 2>&1; then
        # Stop and Remove container
        sudo docker rm -f $i
      else
        echo "Container $i does not exist"
      fi
    done
    # Delete the container file
    rm $container_names_file
  fi

  # Delete networks
  if [ -f "$networks_file" ]; then
    for i in `cat $networks_file`; do
      # Check if network exists and delete
      if sudo docker network inspect $i > /dev/null 2>&1; then
        sudo docker network rm $i
      else
        echo "Network $i does not exist"
      fi
    done
    # Delete network file
    rm $networks_file
  fi

  # Delete files
  for file in "${files_to_be_removed[@]}"; do
    if [ -f "$file" ]; then
      rm $file
    fi
  done

  # Delete files for Docker-in-Docker
  sudo docker run --rm --mount type=bind,source="$PWD",target=/output $docker_cli_image sh -c 'for file in "$@"; do if [ -f "/output/$file" ]; then rm "/output/$file"; fi; done' sh "${files_to_be_removed[@]}"

  # Delete folders. Entries from files_to_be_removed are included in case a
  # Docker-in-Docker bind mount created a directory where a file was expected.
  folders_to_be_removed+=("${files_to_be_removed[@]}")
  for folder in "${folders_to_be_removed[@]}"; do
    if [ -d "$folder" ]; then
      rm -Rf $folder;
    fi
  done

  # Delete folders for Docker-in-Docker
  sudo docker run --rm --mount type=bind,source="$PWD",target=/output $docker_cli_image sh -c 'for folder in "$@"; do if [ -d "/output/$folder" ]; then rm -rf "/output/$folder"; fi; done' sh "${folders_to_be_removed[@]}"

  # Delete stale containers using a deleted parent network
  # (network_mode: container:<parent> where parent no longer exists)
  echo -e "${YELLOW}Deleting stale containers. This may take a few minutes...${NOCOLOUR}"
  declare -A existing
  declare -A container_data  # cid -> "name status netmode image"
  # Single docker inspect call - add --type container to skip images/networks
  while read -r cid cname status netmode image; do
    cname="${cname#/}"
    existing["$cid"]=1
    existing["$cname"]=1
    container_data["$cid"]="$cname $status $netmode $image"
  done < <(sudo docker inspect --type container $(sudo docker ps -aq) --format '{{.Id}} {{.Name}} {{.State.Status}} {{.HostConfig.NetworkMode}} {{.Config.Image}}' 2>/dev/null)
  # Single pass - no second inspect needed
  for cid in "${!container_data[@]}"; do
    read -r cname status netmode image <<< "${container_data[$cid]}"
    # Only process containers with network mode referencing another container
    [[ "$netmode" != container:* ]] && continue
    parent="${netmode#container:}"
    if [[ -z "${existing[$parent]}" ]]; then
      echo -e "${YELLOW}Removing stale container:${NOCOLOUR} $cname ($status)"
      echo -e "${YELLOW}Network Mode:${NOCOLOUR} $netmode"
      echo -e "${YELLOW}Image:${NOCOLOUR} $image"
      sudo docker rm -f "$cname"
    fi
  done
  echo -e "${GREEN}Stale container deletion completed successfully.${NOCOLOUR}"

  SCRIPT_END_TIME=$(date +%s)
  TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

  echo -e "${GREEN}========================================${NOCOLOUR}"
  echo -e "${GREEN}All containers and networks deleted.${NOCOLOUR}"
  echo -e "${GREEN}Delete runtime: $(format_duration $TOTAL_TIME)${NOCOLOUR}"
  echo -e "${GREEN}========================================${NOCOLOUR}"

  exit 0
fi

# Delete backup files and folders
if [[ "$1" == "--deleteBackup" ]]; then
  echo -e "\n\nDeleting backup folders and files.."

  # Check if previous files exist
  for file in "${files_to_be_removed[@]}"; do
    if [ -f "$file" ]; then
      echo -e "${RED}File $file still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash $script_name --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  # Check if previous folders exist
  for folder in "${folders_to_be_removed[@]}"; do
    if [ -d "$folder" ]; then
      echo -e "${RED}Folder $folder still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash $script_name --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  # Delete backup files
  for file in "${back_up_files[@]}"; do
    if [ -f "$file" ]; then
      rm $file
    fi
  done

  # Delete backup files for Docker-in-Docker
  sudo docker run --rm --mount type=bind,source="$PWD",target=/output $docker_cli_image sh -c 'for file in "$@"; do if [ -f "/output/$file" ]; then rm "/output/$file"; fi; done' sh "${back_up_files[@]}"

  # Delete backup folders
  back_up_folders+=("${back_up_files[@]}")
  for folder in "${back_up_folders[@]}"; do
    if [ -d "$folder" ]; then
      rm -Rf $folder;
    fi
  done

  # Delete backup folders for Docker-in-Docker
  sudo docker run --rm --mount type=bind,source="$PWD",target=/output $docker_cli_image sh -c 'for folder in "$@"; do if [ -d "/output/$folder" ]; then rm -rf "/output/$folder"; fi; done' sh "${back_up_folders[@]}"

  exit 0
fi

echo -e "Valid options are: ${RED}--start${NOCOLOUR}, ${RED}--delete${NOCOLOUR}, ${RED}--deleteBackup${NOCOLOUR}, ${RED}--build${NOCOLOUR}, ${RED}--install${NOCOLOUR}"
