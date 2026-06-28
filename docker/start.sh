#!/bin/bash

set -euo pipefail

############################################
# Validate Environment Variables
############################################

if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi

if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

############################################
# Settings
############################################

OVERLAY="overlay.png"
FONT="font.ttf"
CHANNEL_NAME="Your Channel Name"

echo "========================================"
echo "Starting 24/7 YouTube Stream..."
echo "========================================"

IFS=',' read -ra URLS <<< "$VIDEO_URL"

############################################
# Loop Forever
############################################

while true; do

    for url in "${URLS[@]}"; do

        echo "----------------------------------------"
        echo "Streaming: $url"
        echo "----------------------------------------"

        ffmpeg \
        -hide_banner \
        -loglevel warning \
        -re \
        -stream_loop -1 \
        -i "$url" \
        -loop 1 \
        -i "$OVERLAY" \
        -filter_complex "\
        [0:v]scale=1280:720:force_original_aspect_ratio=decrease,\
        pad=1280:720:(ow-iw)/2:(oh-ih)/2[video];\
        [1:v]scale=1280:720[overlay];\
        [video][overlay]overlay=0:0,\
        drawtext=fontfile=${FONT}:\
        text='🔴 LIVE':\
        fontsize=34:\
        fontcolor=red:\
        x=35:\
        y=35,\
        drawtext=fontfile=${FONT}:\
        text='Footage Courtesy: NASA & SpaceX':\
        fontsize=22:\
        fontcolor=white:\
        x=40:\
        y=680,\
        drawtext=fontfile=${FONT}:\
        text='${CHANNEL_NAME}':\
        fontsize=26:\
        fontcolor=white:\
        x=980:\
        y=35,\
        drawtext=fontfile=${FONT}:\
        text='%{localtime}':\
        fontsize=22:\
        fontcolor=yellow:\
        x=1040:\
        y=680" \
        -map 0:a? \
        -c:v libx264 \
        -preset veryfast \
        -pix_fmt yuv420p \
        -r 30 \
        -b:v 3500k \
        -maxrate 3500k \
        -bufsize 7000k \
        -g 60 \
        -keyint_min 60 \
        -c:a aac \
        -b:a 128k \
        -ar 44100 \
        -ac 2 \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || true

        echo "Video finished."

        sleep 5

    done

done
