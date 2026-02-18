#!/bin/bash

######### DO NOT EDIT THE CODE BELOW UNLESS YOU KNOW WHAT YOU ARE DOING  #########
# Colours
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NOCOLOUR="\033[0m"

# File names
properties_file="properties.conf"
banner_file="banner.jpg"
proxies_file="proxies.txt"
containers_file="containers.txt"
container_names_file="containernames.txt"
earnapp_file="earnapp.txt"
earnapp_data_folder="earnappdata"
networks_file="networks.txt"
restart_file="restart.sh"
dns_resolver_file="resolv.conf"
required_files=($banner_file $properties_file $restart_file)
files_to_be_removed=($dns_resolver_file $containers_file $container_names_file $networks_file)
folders_to_be_removed=($earnapp_data_folder)
back_up_folders=()
back_up_files=($earnapp_file)
container_pulled=false
docker_in_docker_detected=false


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

# Start all containers
start_containers() {

  local i=$1
  local proxy=$2
  local DNS_VOLUME="--mount type=bind,source=$PWD/$dns_resolver_file,target=/etc/resolv.conf,readonly"
  local TUN_DNS_VOLUME

  if [ "$container_pulled" = false ]; then
    # For users with Docker-in-Docker, the PWD path is on the host where Docker is installed.
    # The files are created in the same path as the inner Docker path.
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 9.9.9.9\n' > $dns_resolver_file;
    if [ ! -f $dns_resolver_file ]; then
      echo -e "${RED}There is a problem creating resolver file. Exiting..${NOCOLOUR}";
      exit 1;
    fi
    if sudo docker run --rm -v "$PWD:/output" docker:18.06.2-dind sh -c "if [ ! -f /output/$dns_resolver_file ]; then exit 0; else exit 1; fi"; then
      docker_in_docker_detected=true
    fi
    sudo docker run --rm -v $PWD:/output docker:18.06.2-dind sh -c "if [ ! -f /output/$dns_resolver_file ]; then printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 9.9.9.9\n' > /output/$dns_resolver_file; printf 'Docker-in-Docker is detected. The script runs with limited features.\nThe files and folders are created in the same path on the host where your parent docker is installed.\n'; fi"
  fi

  if [[ "$ENABLE_LOGS" != true ]]; then
    LOGS_PARAM="--log-driver none"
    TUN_LOG_PARAM="silent"
  else
    LOGS_PARAM="--log-driver=json-file --log-opt max-size=100k"
    TUN_LOG_PARAM="debug"
  fi

  if [[ $i && $proxy ]]; then
    NETWORK_TUN="--network=container:tun$UNIQUE_ID$i"


    echo -e "${GREEN}Starting Proxy container..${NOCOLOUR}"
    # Starting tun containers
    if [ "$container_pulled" = false ]; then
      if [ "$USE_SOCKS5_DNS" = true ]; then
        sudo docker pull ghcr.io/heiher/hev-socks5-tunnel:latest
      elif [ "$USE_DNS_OVER_HTTPS" = true ]; then
        sudo docker pull ghcr.io/tun2proxy/tun2proxy:v0.7.19
      else
        sudo docker pull xjasonlyu/tun2socks:v2.6.0
      fi
    fi
    if [ "$USE_SOCKS5_DNS" = true ]; then
      TUN_DNS_VOLUME="$DNS_VOLUME"
    elif [ "$USE_DNS_OVER_HTTPS" = true ]; then
      EXTRA_COMMANDS='echo -e "options use-vc\nnameserver 8.8.8.8\nnameserver 8.8.4.4" > /etc/resolv.conf;ip rule add iif lo ipproto udp dport 53 lookup main;'
      DNS_OPTION="--dns over-tcp"
    else
      TUN_DNS_VOLUME="$DNS_VOLUME"
      EXTRA_COMMANDS='ip rule add iif lo ipproto udp dport 53 lookup main;'
    fi
    if [[ "$USE_SOCKS5_DNS" == "true" && "$proxy" == socks5://* ]]; then
      SOCKS_PROXY=$proxy
      # Strip scheme
      SOCKS_NO_SCHEME="${SOCKS_PROXY#socks5://}"
      # If auth exists, split it
      if [[ "$SOCKS_NO_SCHEME" == *@* ]]; then
        SOCKS_CREDS="${SOCKS_NO_SCHEME%@*}"
        SOCKS_HOSTPORT="${SOCKS_NO_SCHEME#*@}"
        SOCKS_USER="${SOCKS_CREDS%%:*}"
        SOCKS_PASS="${SOCKS_CREDS#*:}"
      else
        SOCKS_HOSTPORT="$SOCKS_NO_SCHEME"
        SOCKS_USER=""
        SOCKS_PASS=""
      fi
      SOCKS_ADDR="${SOCKS_HOSTPORT%%:*}"
      SOCKS_PORT="${SOCKS_HOSTPORT##*:}"
      if [[ "$ENABLE_LOGS" != true ]]; then
        TUN_LOG_PARAM="warn"
      fi
      if CONTAINER_ID=$(sudo docker run --name tun$UNIQUE_ID$i $LOGS_PARAM $TUN_DNS_VOLUME --restart=always -e LOG_LEVEL=$TUN_LOG_PARAM -v '/dev/net/tun:/dev/net/tun' --cap-add=NET_ADMIN -e SOCKS5_ADDR="$SOCKS_ADDR" -e SOCKS5_PORT="$SOCKS_PORT" -e SOCKS5_USERNAME="$SOCKS_USER" -e SOCKS5_PASSWORD="$SOCKS_PASS" -d --no-healthcheck ghcr.io/heiher/hev-socks5-tunnel:latest); then
        echo "$CONTAINER_ID" | tee -a $containers_file
        echo "tun$UNIQUE_ID$i" | tee -a $container_names_file
      else
        echo -e "${RED}Failed to start container for proxy. Exiting..${NOCOLOUR}"
        exit 1
      fi
    elif [[ "$USE_DNS_OVER_HTTPS" == "true" && "$proxy" =~ ^(http|https|socks4|socks5):// ]]; then
      if [[ "$ENABLE_LOGS" != true ]]; then
        TUN_LOG_PARAM="off"
      else
        TUN_LOG_PARAM="trace"
      fi
      if CONTAINER_ID=$(sudo docker run --name tun$UNIQUE_ID$i $LOGS_PARAM --restart=always -v '/dev/net/tun:/dev/net/tun' --cap-add=NET_ADMIN -d ghcr.io/tun2proxy/tun2proxy:v0.7.19 $DNS_OPTION --proxy $proxy --verbosity $TUN_LOG_PARAM); then
        echo "$CONTAINER_ID" | tee -a $containers_file
        echo "tun$UNIQUE_ID$i" | tee -a $container_names_file
      else
        echo -e "${RED}Failed to start container for proxy. Exiting..${NOCOLOUR}"
        exit 1
      fi
    else 
      if CONTAINER_ID=$(sudo docker run --name tun$UNIQUE_ID$i $LOGS_PARAM $TUN_DNS_VOLUME --restart=always -e LOGLEVEL=$TUN_LOG_PARAM -e PROXY=$proxy -e EXTRA_COMMANDS="$EXTRA_COMMANDS" -v '/dev/net/tun:/dev/net/tun' --cap-add=NET_ADMIN -d xjasonlyu/tun2socks:v2.6.0); then
        echo "$CONTAINER_ID" | tee -a $containers_file
        echo "tun$UNIQUE_ID$i" | tee -a $container_names_file
      else
        echo -e "${RED}Failed to start container for proxy. Exiting..${NOCOLOUR}"
        exit 1
      fi
    fi
    sleep 1
  fi


  # Starting Earnapp container
  if [ "$EARNAPP" = true ]; then
    echo -e "${GREEN}Starting Earnapp container..${NOCOLOUR}"
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
    if [ "$container_pulled" = false ]; then
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

    if CONTAINER_ID=$(sudo docker run -d --health-interval=24h --name earnapp$UNIQUE_ID$i $LOGS_PARAM $DNS_VOLUME --restart=always $NETWORK_TUN -v $PWD/$earnapp_data_folder/data$i:/etc/earnapp -e EARNAPP_UUID=$uuid "$EARNAPP_IMAGE"); then
      echo "$CONTAINER_ID" | tee -a $containers_file
      echo "earnapp$UNIQUE_ID$i" | tee -a $container_names_file
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
  else
    echo -e "${RED}Docker is not installed. There is a problem installing Docker.${NOCOLOUR}"
    echo "Please install Docker manually by following https://docs.docker.com/engine/install/"
  fi
  exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Docker is not installed, without which the script cannot start. Exiting..${NOCOLOUR}"
  echo -e "To install Docker and its dependencies, please run the following command\n"
  echo -e "${YELLOW}sudo bash internetIncome.sh --install${NOCOLOUR}\n"
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
      echo -e "${YELLOW}sudo bash internetIncome.sh --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  for folder in "${folders_to_be_removed[@]}"; do
    if [ -d "$folder" ]; then
      echo -e "${RED}Folder $folder still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash internetIncome.sh --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  # Remove special characters ^M from properties file
  sed -i 's/\r//g' $properties_file

  # CPU architecture to get docker images
  CPU_ARCH=`uname -m`

  # Read the properties file and export variables to the current shell
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
  done < $properties_file

  # Setting Device name
  if [[ ! $DEVICE_NAME ]]; then
    echo -e "${RED}Device Name is not configured. Using default name ${NOCOLOUR}ubuntu"
    DEVICE_NAME=ubuntu
  fi

  if [ "$USE_PROXIES" = true ]; then
    echo -e "${GREEN}USE_PROXIES is enabled, using proxies..${NOCOLOUR}"
    if [ ! -f "$proxies_file" ]; then
      echo -e "${RED}Proxies file $proxies_file does not exist, exiting..${NOCOLOUR}"
      exit 1
    fi

    # Remove special characters ^M from proxies file
    sed -i 's/\r//g' $proxies_file

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

  SCRIPT_END_TIME=$(date +%s)
  TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

  echo -e "${GREEN}========================================${NOCOLOUR}"
  echo -e "${GREEN}All containers processed.${NOCOLOUR}"
  echo -e "${GREEN}Total runtime: $(format_duration $TOTAL_TIME)${NOCOLOUR}"
  echo -e "${GREEN}========================================${NOCOLOUR}"
  
  exit 1
fi

# Delete containers and networks
if [[ "$1" == "--delete" ]]; then
  echo -e "\n\nDeleting Containers and networks.."
  SCRIPT_START_TIME=$(date +%s)

  # Delete containers by container names
  if [ -f "$container_names_file" ]; then
    for i in `cat $container_names_file`; do
      # Check if container exists
      if sudo docker inspect $i >/dev/null 2>&1; then
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
  sudo docker run --rm -v "$PWD:/output" docker:18.06.2-dind sh -c 'for file in "$@"; do if [ -f "/output/$file" ]; then rm "/output/$file"; fi; done' sh "${files_to_be_removed[@]}"

  # Delete folders
  for folder in "${folders_to_be_removed[@]}"; do
    if [ -d "$folder" ]; then
      rm -Rf $folder;
    fi
  done

  # Delete folders for Docker-in-Docker
  sudo docker run --rm -v "$PWD:/output" docker:18.06.2-dind sh -c 'for folder in "$@"; do if [ -d "/output/$folder" ]; then rm -rf "/output/$folder"; fi; done' sh "${folders_to_be_removed[@]}"

  SCRIPT_END_TIME=$(date +%s)
  TOTAL_TIME=$((SCRIPT_END_TIME - SCRIPT_START_TIME))

  echo -e "${GREEN}========================================${NOCOLOUR}"
  echo -e "${GREEN}All containers and networks deleted.${NOCOLOUR}"
  echo -e "${GREEN}Delete runtime: $(format_duration $TOTAL_TIME)${NOCOLOUR}"
  echo -e "${GREEN}========================================${NOCOLOUR}"


  exit 1
fi

# Delete backup files and folders
if [[ "$1" == "--deleteBackup" ]]; then
  echo -e "\n\nDeleting backup folders and files.."

  # Check if previous files exist
  for file in "${files_to_be_removed[@]}"; do
    if [ -f "$file" ]; then
      echo -e "${RED}File $file still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash internetIncome.sh --delete${NOCOLOUR}\n"
      exit 1
    fi
  done

  # Check if previous folders exist
  for folder in "${folders_to_be_removed[@]}"; do
    if [ -d "$folder" ]; then
      echo -e "${RED}Folder $folder still exists, there might be containers still running. Please stop them and delete before running the script. Exiting..${NOCOLOUR}"
      echo -e "To stop and delete containers run the following command\n"
      echo -e "${YELLOW}sudo bash internetIncome.sh --delete${NOCOLOUR}\n"
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
  sudo docker run --rm -v "$PWD:/output" docker:18.06.2-dind sh -c 'for file in "$@"; do if [ -f "/output/$file" ]; then rm "/output/$file"; fi; done' sh "${back_up_files[@]}"

  # Delete backup folders
  for folder in "${back_up_folders[@]}"; do
    if [ -d "$folder" ]; then
      rm -Rf $folder;
    fi
  done

  # Delete backup folders for Docker-in-Docker
  sudo docker run --rm -v "$PWD:/output" docker:18.06.2-dind sh -c 'for folder in "$@"; do if [ -d "/output/$folder" ]; then rm -rf "/output/$folder"; fi; done' sh "${back_up_folders[@]}"

  exit 1
fi

echo -e "Valid options are: ${RED}--start${NOCOLOUR}, ${RED}--delete${NOCOLOUR}, ${RED}--deleteBackup${NOCOLOUR}"
