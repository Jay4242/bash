#!/bin/bash
unset IPFS_PATH
# set DigitalOcean variables
REGION="tor1"
SIZE="s-8vcpu-16gb"
IMAGE="ubuntu-22-10-x64"
SSH_KEY=""  #Enter numerical SSH key ID from doctl.

# set video file path
VIDEO_FILE="$1"

# check if video file exists
if [ ! -f "$VIDEO_FILE" ]; then
  echo "Error: $VIDEO_FILE not found"
  exit 1
fi

#add file to IPFS
ipfsCID=$(ipfs add -Q -w "$VIDEO_FILE")
echo "Pinned ${VIDEO_FILE} as ${ipfsCID}"
# create droplet using doctl
droplet_id=$(doctl compute droplet create \
  --image "$IMAGE" \
  --region "$REGION" \
  --size "$SIZE" \
  --ssh-keys "$SSH_KEY" \
  --format ID \
  --wait \
  --no-header ffmpeg-cloud-$(date +%s))

# check if droplet creation was successful
if [ -z "$droplet_id" ]; then
  echo "Error: Droplet creation failed"
  ipfs pin rm -r "${ipfsCID}"
  exit 1
fi

# get the droplet IP address
droplet_ip=$(doctl compute droplet get $droplet_id --format PublicIPv4 --no-header)

# wait for SSH to be available
until ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'exit' &>/dev/null; do sleep 1; done
input_filename=$(basename "$VIDEO_FILE")
slash_name=$(echo "${input_filename}" | sed -e 's/ /\\ /g' -e 's/(/\\(/g' -e 's/)/\\)/g')
# transfer video file to droplet
#scp -o "StrictHostKeyChecking=no" "$VIDEO_FILE" "root@$droplet_ip:${slash_name}"

# check if video file transfer was successful
#if [ $? -ne 0 ]; then
#  echo "Error: Video file transfer failed"
#  doctl compute droplet delete $droplet_id --force
#  exit 1
#fi

# install ffmpeg and any other needed software
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'wget https://dist.ipfs.tech/kubo/v0.18.1/kubo_v0.18.1_linux-amd64.tar.gz'
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'tar xzvf kubo_v0.18.1_linux-amd64.tar.gz && cd kubo && sudo ./install.sh && ipfs init'
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'ipfs daemon' &>/dev/null &
sshpid=$!
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'until apt-get update && apt-get install -y ffmpeg ; do sleep 3 ; done'
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'mkdir /ipfs && mkdir /ipns && ipfs mount'
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip "ipfs get /ipfs/${ipfsCID}" > /dev/null 2>&1 &
swarmpid=$!
echo "Reminder ${VIDEO_FILE} was pinned as ${ipfsCID}"
# encode video with ffmpeg and save output to file with "_reconvert" suffix
input_filename=$(basename "$VIDEO_FILE")
output_filename="${input_filename%.*}_reconvert.${input_filename##*.}"
out_slash_name=$(echo "$output_filename" | sed -e 's/ /\\ /g' -e 's/(/\\(/g' -e 's/)/\\)/g')
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip 'ipfs swarm connect YOUR-LOCAL-IPFS-ID'  #Change to your local IPFS id from the 'ipfs id' command that shows your reachable address.
ssh -o "StrictHostKeyChecking=no" root@$droplet_ip "ffmpeg -i '/ipfs/${ipfsCID}/${input_filename}' -c:v libx264 -preset veryslow -crf 23 -c:a copy -movflags faststart '$output_filename'"

# check if video encoding was successful
if [ $? -ne 0 ]; then
  echo "Error: Video encoding failed"
  doctl compute droplet delete $droplet_id --force
  ipfs pin rm -r "${ipfsCID}"
  kill -- "${sshpid}"
  kill -- "${swarmpid}"
  exit 1
fi

# check if output file exists
if ssh -o "StrictHostKeyChecking=no" root@$droplet_ip "[ ! -f '$output_filename' ]"; then
  echo "Error: Output file not found"
  doctl compute droplet delete $droplet_id --force
  ipfs pin rm -r "${ipfsCID}"
  kill -- "${sshpid}"
  kill -- "${swarmpid}"
  exit 1
fi

# check if output file is smaller than input file
input_size=$(wc -c < "$VIDEO_FILE")
output_size=$(ssh -o "StrictHostKeyChecking=no" root@$droplet_ip "wc -c < '$output_filename'")
if [ $output_size -ge $input_size ]; then
  echo "Warning: Encoding was not successful in saving any space"
  doctl compute droplet delete $droplet_id --force
  ipfs pin rm -r "${ipfsCID}"
  kill -- "${sshpid}"
  kill -- "${swarmpid}"
else
  # download the encoded file back to the local machine
  scp -o "StrictHostKeyChecking=no" "root@$droplet_ip:/root/$out_slash_name" "$output_filename"
  #delete the droplet
  doctl compute droplet delete $droplet_id --force
  ls -lah "$VIDEO_FILE"
  ls -lah "$output_filename"
  # prompt the user to delete the original file
  read -p "Do you want to delete the original file? (y/n) " choice
  case "$choice" in 
    y|Y )
      # use trash command to delete the original file
      trash "$VIDEO_FILE"
      ;;
    n|N ) 
      echo "Original file was not deleted."
      ;;
    * ) 
      echo
esac

ipfs pin rm -r "${ipfsCID}"
kill -- "${sshpid}"
kill -- "${swarmpid}"
fi
