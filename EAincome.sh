#!/bin/bash

# Colours
RED="\033[0;31m"
GREEN="\033[0;32m"
NOCOLOUR="\033[0m"

earnapp_file="earnapp.txt"
earnapp_data_folder="earnappdata"
container_names_file="containernames.txt"

UNIQUE_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 8)

# Install Docker
if [[ "$1" == "--install" ]]; then
  sudo apt-get update
  sudo apt-get -y install docker.io
  echo -e "${GREEN}Docker installed.${NOCOLOUR}"
  exit 0
fi

# Check Docker
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Docker not installed. Run with --install${NOCOLOUR}"
  exit 1
fi

# Start EarnApp
if [[ "$1" == "--start" ]]; then
  echo -e "${GREEN}Starting EarnApp...${NOCOLOUR}"

  RANDOM_ID=$(cat /dev/urandom | tr -dc 'a-f0-9' | head -c 32)
  uuid="sdk-node-$RANDOM_ID"

  date_time=$(date "+%D %T")
  printf "$date_time https://earnapp.com/r/%s\n" "$uuid" | tee -a $earnapp_file

  mkdir -p $PWD/$earnapp_data_folder
  sudo chmod -R 777 $PWD/$earnapp_data_folder

  sudo docker pull fazalfarhan01/earnapp:lite

  CONTAINER_ID=$(sudo docker run -d \
    --name earnapp$UNIQUE_ID \
    --restart=always \
    -v $PWD/$earnapp_data_folder:/etc/earnapp \
    -e EARNAPP_UUID=$uuid \
    fazalfarhan01/earnapp:lite)

  if [[ $CONTAINER_ID ]]; then
    echo "$CONTAINER_ID" | tee -a $container_names_file
    echo -e "${GREEN}EarnApp started successfully.${NOCOLOUR}"
    echo -e "${GREEN}Register this node in dashboard:${NOCOLOUR}"
    echo -e "https://earnapp.com/r/$uuid"
  else
    echo -e "${RED}Failed to start EarnApp.${NOCOLOUR}"
  fi

  exit 0
fi

# Delete
if [[ "$1" == "--delete" ]]; then
  echo -e "${GREEN}Deleting containers...${NOCOLOUR}"

  if [ -f "$container_names_file" ]; then
    while read name; do
      sudo docker rm -f "$name"
    done < $container_names_file
    rm $container_names_file
  fi

  rm -rf $earnapp_data_folder
  echo -e "${GREEN}Cleanup complete.${NOCOLOUR}"
  exit 0
fi

echo -e "Valid options: --start | --delete | --install"
