#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream"
echo "Output Resolution : 1920x1080"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6   # seconds each headline is shown

mkdir -p "$ASSET_DIR"

#############################################
# Static panel text (title + section header)
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"

#############################################
# Load headlines from galaxy_info.txt
# (one headline per line, blank lines ignored)
#############################################
RAW_LINES=()
if [ -f "$INFO_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
    done < "$INFO_FILE"
fi

# Fallback if the file is missing or empty
if [ "${#RAW_LINES[@]}" -eq 0 ]; then
    echo "WARNING: $INFO_FILE not found or empty — using default headlines."
    RAW_LINES=(
    "Webb captured light from galaxies formed just over 300 million years after the Big Bang, revealing the early Universe."
    "The James Webb Space Telescope observes the cosmos primarily using infrared light, allowing it to see through dense cosmic dust."
    "Webb discovered some of the oldest and most distant galaxies ever observed, expanding our understanding of cosmic evolution."
    "Infrared observations from Webb reveal hidden star-forming regions where new stars are born inside giant molecular clouds."
    "Webb detected water vapor in the atmosphere of distant exoplanets, helping scientists search for potentially habitable worlds."
    "The telescope's massive gold-coated mirror spans 6.5 meters, collecting significantly more light than the Hubble Space Telescope."
    "James Webb studies the birth and evolution of galaxies, stars, and planetary systems across billions of years of cosmic history."
    "Webb observed the famous Pillars of Creation with unprecedented clarity, exposing countless newborn stars hidden behind thick dust."
    "The telescope operates nearly 1.5 million kilometers from Earth at the second Sun-Earth Lagrange point for stable observations."
    "Webb's powerful infrared cameras can detect extremely faint objects that remain invisible to traditional optical telescopes."
    "Scientists use Webb to analyze the chemical composition of distant planets by studying how starlight passes through their atmospheres."
    "The Cartwheel Galaxy images revealed intricate rings, star formation, and collision debris from a dramatic galactic encounter."
    "Webb discovered complex organic molecules inside distant star-forming regions, providing clues about the origins of planetary systems."
    "The telescope's sunshield is the size of a tennis court and keeps its sensitive instruments extremely cold during observations."
    "Webb has revealed detailed structures inside planetary nebulae, showing how dying stars enrich space with essential elements."
    "Astronomers use Webb to investigate supermassive black holes that formed surprisingly early in the history of the Universe."
    "Infrared images from Webb uncovered thousands of previously hidden galaxies within tiny regions of the night sky."
    "Webb observed the atmosphere of giant exoplanets and detected carbon dioxide, methane, and water using advanced spectroscopic instruments."
    "Scientists believe Webb will continue transforming astronomy by discovering unexpected cosmic objects and answering fundamental questions about space."
    "The telescope helps researchers understand how galaxies merge, grow, and evolve through billions of years of gravitational interactions."
    "Webb's observations provide valuable evidence about how the first stars ignited and illuminated the once-dark early Universe."
    "The telescope studies icy moons, asteroids, and planets within our Solar System, revealing remarkable surface and atmospheric details."
    "Webb identified young stellar disks containing the ingredients required for future planet formation around newly born stars."
    "Astronomers combine Webb observations with Hubble data to create detailed multiwavelength views of galaxies, nebulae, and star clusters."
    "Every new Webb observation expands humanity's understanding of the Universe, inspiring future discoveries about space, time, galaxies, and life."
)
fi

N=${#RAW_LINES[@]}
CYCLE=$((N * SLOT))
echo "Loaded $N headline(s) from $INFO_FILE — rotation cycle: ${CYCLE}s"

# Wrap each headline to fit the panel width and write it to its own file
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    echo "${RAW_LINES[$i]}" | fold -s -w 30 > "$ASSET_DIR/headline${idx}.txt"
done

#############################################
# Build the filter_complex dynamically
#############################################
CHAIN="[0:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[video];"
CHAIN+="[1:v]scale=1920:1080:flags=lanczos[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base];"
CHAIN+="[base]drawbox=x=0:y=0:w=520:h=1080:color=black@0.55:t=fill[p1];"
CHAIN+="[p1]drawbox=x=0:y=0:w=520:h=8:color=${GOLD}@0.9:t=fill[p2];"
CHAIN+="[p2]drawbox=x=514:y=0:w=4:h=1080:color=${GOLD}@0.7:t=fill[p3];"
CHAIN+="[p3]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=red:fontsize=60:x=40:y=25[p4];"
CHAIN+="[p4]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white:fontsize=42:x=w-text_w-30:y=20[p5];"
CHAIN+="[p5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=34:x=50:y=115[p6];"
CHAIN+="[p6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white:fontsize=28:x=50:y=160[p7];"
CHAIN+="[p7]drawbox=x=50:y=210:w=420:h=2:color=white@0.35:t=fill[p8];"
CHAIN+="[p8]drawbox=x=50:y=234:w=12:h=12:color=${GOLD}:t=fill[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=22:x=74:y=230[p10];"

prev="p10"
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    start=$((i * SLOT))
    end=$((start + SLOT))
    nxt="h${idx}"
    ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=30:line_spacing=14:x=50:y=300:alpha='${ALPHA}'[${nxt}];"
    prev="$nxt"
done

# background dots (dim)
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((50 + i * 26))
    nxt="db${idx}"
    CHAIN+="[${prev}]drawbox=x=${x}:y=950:w=10:h=10:color=white@0.3:t=fill[${nxt}];"
    prev="$nxt"
done

# active dot (gold, toggled on/off per slot)
last=$((N - 1))
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((50 + i * 26))
    start=$((i * SLOT))
    end=$((start + SLOT))
    ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
    if [ "$i" -eq "$last" ]; then
        CHAIN+="[${prev}]drawbox=x=${x}:y=950:w=10:h=10:color=${GOLD}:t=fill:enable='${ENABLE}'"
    else
        nxt="da${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=950:w=10:h=10:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
        prev="$nxt"
    fi
done

FILTER="$CHAIN"

#############################################
# Stream loop
#############################################
IFS=',' read -ra URLS <<< "$VIDEO_URL"
while true; do
    for url in "${URLS[@]}"; do
        echo "----------------------------------------"
        echo "Streaming:"
        echo "$url"
        echo "----------------------------------------"

        ffmpeg \
        -hide_banner \
        -loglevel info \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -filter_complex "$FILTER" \
        -r 30 \
        -s 1920x1080 \
        -c:v libx264 \
        -preset superfast \
        -profile:v high \
        -level 4.2 \
        -pix_fmt yuv420p \
        -b:v 6000k \
        -maxrate 6000k \
        -bufsize 12000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 160k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"

        echo ""
        echo "Video Finished."
        echo "Loading next video in 5 seconds..."
        echo ""
        sleep 5
    done
done
