set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends mpv audacity
echo 'Media bundle installed.'
