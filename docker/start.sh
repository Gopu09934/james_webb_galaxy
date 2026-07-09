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
echo "Starting 24/7 YouTube Stream (Documentary Overlay)"
echo "Output Resolution : 1920x1080"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6            # seconds each headline is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll

mkdir -p "$ASSET_DIR"

#############################################
# Static panel text
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"
printf 'DEEP SPACE REPORT'                > "$ASSET_DIR/eyebrow.txt"

#############################################
# Load headlines from galaxy_info.txt
#############################################
RAW_LINES=()
if [ -f "$INFO_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
    done < "$INFO_FILE"
fi

if [ "${#RAW_LINES[@]}" -eq 0 ]; then
    echo "WARNING: $INFO_FILE not found or empty — using default headlines."
    RAW_LINES=(
        "Webb reveals one of the oldest galaxies ever discovered."
        "Infrared observations uncover hidden star-forming regions."
        "The Cartwheel Galaxy was formed after a galactic collision."
        "Scientists continue studying the earliest galaxies in the Universe."
    )
fi

N=${#RAW_LINES[@]}
CYCLE=$((N * SLOT))
echo "Loaded $N headline(s) from $INFO_FILE — rotation cycle: ${CYCLE}s"

# Wrap each headline for the side panel
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    echo "${RAW_LINES[$i]}" | fold -s -w 30 > "$ASSET_DIR/headline${idx}.txt"
done

# Build one long ticker string for the bottom scroll bar
TICKER_STRING=""
for i in "${!RAW_LINES[@]}"; do
    TICKER_STRING+="${RAW_LINES[$i]}     •     "
done
printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

#############################################
# Build the filter_complex dynamically
#############################################

# --- base video + vignette + background art -------------------------------
CHAIN="[0:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,vignette=PI/5[video];"
CHAIN+="[1:v]scale=1920:1080:flags=lanczos[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base];"

# --- left info panel with feathered (gradient-style) edge -----------------
CHAIN+="[base]drawbox=x=0:y=0:w=500:h=1080:color=black@0.60:t=fill[p1];"
CHAIN+="[p1]drawbox=x=500:y=0:w=6:h=1080:color=black@0.45:t=fill[p2];"
CHAIN+="[p2]drawbox=x=506:y=0:w=6:h=1080:color=black@0.30:t=fill[p3];"
CHAIN+="[p3]drawbox=x=512:y=0:w=6:h=1080:color=black@0.15:t=fill[p4];"
CHAIN+="[p4]drawbox=x=0:y=0:w=520:h=6:color=${GOLD}@0.9:t=fill[p5];"
CHAIN+="[p5]drawbox=x=518:y=0:w=3:h=1080:color=${GOLD}@0.6:t=fill[p6];"

# --- LIVE indicator: steady label + blinking dot ---------------------------
CHAIN+="[p6]drawbox=x=40:y=42:w=16:h=16:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=44:x=66:y=28[p8];"

# --- credits + live UTC clock ----------------------------------------------
CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=30:x=w-text_w-30:y=20[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:text='%{gmtime\\:%H\\\\:%M\\\\:%S}  UTC':fontcolor=${GOLD}:fontsize=28:x=w-text_w-30:y=58[p10];"

# --- titles ------------------------------------------------------------
CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=34:x=50:y=125[p11];"
CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=26:x=50:y=168[p12];"
CHAIN+="[p12]drawbox=x=50:y=214:w=420:h=2:color=white@0.3:t=fill[p13];"

# --- section header ----------------------------------------------------
CHAIN+="[p13]drawbox=x=50:y=238:w=12:h=12:color=${GOLD}:t=fill[p14];"
CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=22:x=74:y=234[p15];"

# --- eyebrow category tag above the rotating headline -----------------
CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.85:fontsize=17:x=50:y=280[p16];"

prev="p16"
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    start=$((i * SLOT))
    end=$((start + SLOT))
    nxt="h${idx}"
    ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=32:line_spacing=14:x=50:y=310:alpha='${ALPHA}'[${nxt}];"
    prev="$nxt"
done

# --- animated progress bar: fills across current headline's time slot -----
CHAIN+="[${prev}]drawbox=x=50:y=470:w=420:h=3:color=white@0.15:t=fill[pg1];"
CHAIN+="[pg1]drawbox=x=50:y=470:w='420*(mod(t\,${SLOT}))/${SLOT}':h=3:color=${GOLD}:t=fill[pg2];"
prev="pg2"

# --- background dots (dim) -------------------------------------------------
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((50 + i * 26))
    nxt="db${idx}"
    CHAIN+="[${prev}]drawbox=x=${x}:y=500:w=10:h=10:color=white@0.3:t=fill[${nxt}];"
    prev="$nxt"
done

# --- active dot (gold, toggled per slot) -----------------------------------
last=$((N - 1))
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((50 + i * 26))
    start=$((i * SLOT))
    end=$((start + SLOT))
    ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
    if [ "$i" -eq "$last" ]; then
        CHAIN+="[${prev}]drawbox=x=${x}:y=500:w=10:h=10:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
        prev="pdotend"
    else
        nxt="da${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=500:w=10:h=10:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
        prev="$nxt"
    fi
done

# --- bottom ticker bar -------------------------------------------------
CHAIN+="[${prev}]drawbox=x=0:y=1020:w=1920:h=60:color=black@0.72:t=fill[tk1];"
CHAIN+="[tk1]drawbox=x=0:y=1020:w=1920:h=3:color=${GOLD}@0.9:t=fill[tk2];"
CHAIN+="[tk2]drawbox=x=0:y=1023:w=170:h=57:color=${GOLD}:t=fill[tk3];"
CHAIN+="[tk3]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=24:x=25:y=1043[tk4];"
CHAIN+="[tk4]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=26:y=1043:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk5];"

# --- outer frame border -------------------------------------------------
CHAIN+="[tk5]drawbox=x=0:y=0:w=1920:h=1080:color=black@0.5:t=2[final]"

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
        -map "[final]" \
        -map 0:a? \
        -r 30 \
        -s 1920x1080 \
        -c:v libx264 \
        -preset ultrafast \
        -profile:v high \
        -level 4.2 \
        -pix_fmt yuv420p \
        -b:v 2500k \
        -maxrate 2500k \
        -bufsize 4000k \
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
