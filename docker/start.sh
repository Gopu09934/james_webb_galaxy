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
echo "Starting 24/7 YouTube Stream (Twinkling Stars + Overlay)"
echo "Output Resolution : 1280x720 (720p)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll

ENABLE_BUMPER=true
BUMPER_DURATION=5
BUMPER_MESSAGES=(
    "Stay tuned for more cosmic wonders"
    "Another journey through deep space is coming up"
    "More discoveries from the edge of the universe"
    "The story of the cosmos continues"
)

MAX_RETRIES=5
RETRY_DELAY=5

mkdir -p "$ASSET_DIR"

#############################################
# Clock writer background
#############################################
date -u +'%H:%M:%S  UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%H:%M:%S  UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!
trap 'kill "$CLOCK_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"
printf 'DEEP SPACE REPORT'                > "$ASSET_DIR/eyebrow.txt"

#############################################
# Generate twinkling starfield layers
# (Three layers with different densities for richer twinkling effect)
#############################################
python3 - "$ASSET_DIR" <<'PYEOF'
import random, sys
from PIL import Image, ImageDraw

out_dir = sys.argv[1]
W, H = 1280, 720
random.seed(7)

def make_star_layer(path, count, min_size=1, max_size=2):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x = random.randint(0, W - 1)
        y = random.randint(0, H - 1)
        r = random.randint(min_size, max_size)
        base_a = random.randint(100, 255)
        color = (255, 255, 255, base_a)
        if r == 1:
            d.point((x, y), fill=color)
        else:
            d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    img.save(path)

make_star_layer(f"{out_dir}/stars_a.png", 180)   # dense layer
make_star_layer(f"{out_dir}/stars_b.png", 140)   # medium layer
make_star_layer(f"{out_dir}/stars_c.png", 100)   # sparse layer
PYEOF
echo "✓ Generated 3 star layers: stars_a.png, stars_b.png, stars_c.png"

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
    "The James Webb Space Telescope continues revealing distant galaxies from the early Universe."
    "Webb observations are helping scientists understand how the first stars and galaxies formed."
    "Astronomers have discovered massive black holes growing in some of the Universe's earliest galaxies."
    "New infrared data is uncovering hidden star formation behind cosmic dust clouds."
    "Scientists are using Webb to study exoplanet atmospheres and search for signs of chemical diversity."
    "New observations are changing our understanding of galaxy evolution across billions of years."
    "Space missions are collecting valuable data about dark matter, cosmic expansion, and the structure of the Universe."
    "Astronomers are discovering new exoplanets that reveal the incredible diversity of planetary systems."
    "The study of gravitational waves is opening a new way to observe powerful cosmic events."
    "Scientists are mapping distant galaxies to understand how the Universe expanded over time."
    "Future space telescopes will explore the origins of stars, planets, and galaxies in greater detail."
    "Researchers are using advanced simulations to recreate the formation of cosmic structures."
)
fi

N=${#RAW_LINES[@]}
CYCLE=$((N * SLOT))
echo "✓ Loaded $N headlines — rotation cycle: ${CYCLE}s"

for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
done

# Figure out tallest headline
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
MAX_HEADLINE_LINES=1
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
    [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
done

HEADLINE_Y=218
PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 12))
DOTS_Y=$((PROGRESS_Y + 20))
FACT_DIVIDER_Y=$((DOTS_Y + 40))
FACT_LABEL_Y=$((FACT_DIVIDER_Y + 14))
FACT_TEXT_Y=$((FACT_LABEL_Y + 20))

# Build ticker string
TICKER_STRING=""
for i in "${!RAW_LINES[@]}"; do
    TICKER_STRING+="${RAW_LINES[$i]}     •     "
done
printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

#############################################
# Load fun facts
#############################################
FACTS=()
if [ -f "facts.txt" ]; then
    while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
    done < "facts.txt"
fi
if [ "${#FACTS[@]}" -eq 0 ]; then
    FACTS=(
    "A light-year is the distance light travels in one year, about 9.46 trillion kilometers."
    "The James Webb Space Telescope can observe galaxies that formed more than 13 billion years ago."
    "Neutron stars are so dense that a teaspoon of their material would weigh billions of tons on Earth."
    "Saturn's rings are mostly made of ice particles, rocks, and dust."
    "The Sun contains about 99.8 percent of the total mass in our solar system."
    "The Milky Way galaxy contains hundreds of billions of stars."
    "The Universe is estimated to be about 13.8 billion years old."
    "A black hole's gravity is so strong that even light cannot escape from beyond its event horizon."
    "Mars has the largest volcano in the solar system, Olympus Mons."
    "Jupiter is the largest planet in our solar system."
)
fi
FACT_N=${#FACTS[@]}
FACT_CYCLE=$((FACT_N * FACT_SLOT))
for i in "${!FACTS[@]}"; do
    idx=$((i + 1))
    echo "${FACTS[$i]}" | fold -s -w 23 > "$ASSET_DIR/fact${idx}.txt"
done
printf 'DID YOU KNOW' > "$ASSET_DIR/fact_label.txt"

#############################################
# Build filter_complex
#############################################

# Base video
CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base0];"

# Three star layers with slow horizontal panning and variable opacity
# Each layer moves at a different speed for depth effect
CHAIN+="[2:v]scale=1280:720[star_a_raw];"
CHAIN+="[3:v]scale=1280:720[star_b_raw];"
CHAIN+="[4:v]scale=1280:720[star_c_raw];"

# Layer A: slow pan left, opacity 0.4
CHAIN+="[star_a_raw]format=rgba,pad=iw*2:ih:(iw-mod(t*20\,iw*2)):0[star_a_pan];"
CHAIN+="[star_a_pan]crop=1280:720:0:0,format=rgba[star_a];"

# Layer B: slower pan, opacity 0.3, different direction
CHAIN+="[star_b_raw]format=rgba,pad=iw*2:ih:(iw-mod(t*15\,iw*2)):0[star_b_pan];"
CHAIN+="[star_b_pan]crop=1280:720:0:0,format=rgba[star_b];"

# Layer C: slowest, opacity 0.25
CHAIN+="[star_c_raw]format=rgba,pad=iw*2:ih:(iw-mod(t*10\,iw*2)):0[star_c_pan];"
CHAIN+="[star_c_pan]crop=1280:720:0:0,format=rgba[star_c];"

# Overlay all three star layers with opacity
CHAIN+="[base0][star_a]overlay=0:0:alpha=0.40[with_a];"
CHAIN+="[with_a][star_b]overlay=0:0:alpha=0.30[with_b];"
CHAIN+="[with_b][star_c]overlay=0:0:alpha=0.25[base];"

# Left info panel with feathered edge
CHAIN+="[base]drawbox=x=0:y=0:w=333:h=720:color=black@0.60:t=fill[p1];"
CHAIN+="[p1]drawbox=x=333:y=0:w=4:h=720:color=black@0.45:t=fill[p2];"
CHAIN+="[p2]drawbox=x=337:y=0:w=4:h=720:color=black@0.30:t=fill[p3];"
CHAIN+="[p3]drawbox=x=341:y=0:w=4:h=720:color=black@0.15:t=fill[p4];"
CHAIN+="[p4]drawbox=x=0:y=0:w=347:h=4:color=${GOLD}@0.9:t=fill[p5];"
CHAIN+="[p5]drawbox=x=345:y=0:w=2:h=720:color=${GOLD}@0.6:t=fill[p6];"

# LIVE indicator
CHAIN+="[p6]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p8];"

# Credits + clock
CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=15:x=313-text_w:y=19[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=313-text_w:y=39[p10];"

# Titles
CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=23:x=33:y=83[p11];"
CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=17:x=33:y=112[p12];"
CHAIN+="[p12]drawbox=x=33:y=143:w=280:h=2:color=white@0.3:t=fill[p13];"

# Section header
CHAIN+="[p13]drawbox=x=33:y=159:w=8:h=8:color=${GOLD}:t=fill[p14];"
CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=15:x=49:y=156[p15];"

# Eyebrow tag
CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=198[p16];"

prev="p16"

# Rotating headlines
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    start=$((i * SLOT))
    end=$((start + SLOT))
    nxt="h${idx}"
    ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=33:y=${HEADLINE_Y}:alpha='${ALPHA}'[${nxt}];"
    prev="$nxt"
done

# Progress bar
CHAIN+="[${prev}]drawbox=x=33:y=${PROGRESS_Y}:w=280:h=2:color=white@0.15:t=fill[pg1];"
CHAIN+="[pg1]drawbox=x=33:y=${PROGRESS_Y}:w='280*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
prev="pg2"

# Dots
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((33 + i * 17))
    nxt="db${idx}"
    CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
    prev="$nxt"
done

# Active dot
last=$((N - 1))
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((33 + i * 17))
    start=$((i * SLOT))
    end=$((start + SLOT))
    ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
    if [ "$i" -eq "$last" ]; then
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
        prev="pdotend"
    else
        nxt="da${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
        prev="$nxt"
    fi
done

# Facts
CHAIN+="[${prev}]drawbox=x=33:y=${FACT_DIVIDER_Y}:w=280:h=2:color=${GOLD}@0.4:t=fill[fp1];"
CHAIN+="[fp1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=${FACT_LABEL_Y}[fp2];"
prev="fp2"
for i in "${!FACTS[@]}"; do
    idx=$((i + 1))
    start=$((i * FACT_SLOT))
    end=$((start + FACT_SLOT))
    nxt="f${idx}"
    FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=16:line_spacing=7:x=33:y=${FACT_TEXT_Y}:alpha='${FALPHA}'[${nxt}];"
    prev="$nxt"
done

# Subscribe CTA
CTA_CYCLE=240
CTA_SHOW=8
CTA_START=0
CTA_END=$CTA_SHOW
CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,${CTA_START}\,${CTA_END})\,if(lt(mod(t\,${CTA_CYCLE})-${CTA_START}\,0.6)\,(mod(t\,${CTA_CYCLE})-${CTA_START})/0.6\,if(gt(mod(t\,${CTA_CYCLE})-${CTA_START}\,${CTA_SHOW}-0.6)\,(${CTA_END}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,${CTA_START}\,${CTA_END})"
printf 'SUBSCRIBE for daily space discoveries' > "$ASSET_DIR/cta.txt"
CHAIN+="[${prev}]drawbox=x=733:y=620:w=507:h=43:color=black@0.75:t=fill:enable='${CTA_ENABLE}'[cta1];"
CHAIN+="[cta1]drawbox=x=733:y=620:w=4:h=43:color=${GOLD}:t=fill:enable='${CTA_ENABLE}'[cta2];"
CHAIN+="[cta2]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta3];"
CHAIN+="[cta3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta4];"
prev="cta4"

# Ticker
CHAIN+="[${prev}]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
CHAIN+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
CHAIN+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
CHAIN+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.85:t=fill[tk4];"
CHAIN+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
CHAIN+="[tk5]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=16:x=17:y=695[tk6];"

# Frame border
CHAIN+="[tk6]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

FILTER="$CHAIN"

#############################################
# Bumper between videos
#############################################
run_bumper() {
    local next_url="$1"

    local raw title
    raw="${next_url##*/}"
    raw="${raw%.*}"
    raw="${raw//[-_]/ }"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
        title="A New Discovery"
    else
        raw="${next_url##*/}"
        raw="${raw%.*}"
        raw="${raw//[-_]/ }"
        title=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
    fi

    local sub_idx=$((RANDOM % ${#BUMPER_MESSAGES[@]}))
    printf '%s' "$title" | fold -s -w 34 > "$ASSET_DIR/bumper_title.txt"
    printf '%s' "${BUMPER_MESSAGES[$sub_idx]}" > "$ASSET_DIR/bumper_sub.txt"

    echo ">>> Up next: $title"

    local fade_out_start
    fade_out_start=$(awk -v d="$BUMPER_DURATION" 'BEGIN{print d - 0.6}')

    local BFILTER
    BFILTER="[0:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720[bg];"
    BFILTER+="[bg]drawbox=x=0:y=0:w=1280:h=720:color=black@0.55:t=fill[b1];"
    BFILTER+="[b1]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[b2];"
    BFILTER+="[b2]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[b3];"
    BFILTER+="[b3]drawbox=x=0:y=313:w=1280:h=2:color=${GOLD}@0.8:t=fill[b4];"
    BFILTER+="[b4]drawtext=fontfile=${FONT}:text='UP NEXT':fontcolor=${GOLD}:fontsize=22:x=(w-text_w)/2:y=260[b5];"
    BFILTER+="[b5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_title.txt:fontcolor=white:fontsize=36:line_spacing=8:x=(w-text_w)/2:y=347[b6];"
    BFILTER+="[b6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_sub.txt:fontcolor=white@0.75:fontsize=18:x=(w-text_w)/2:y=427[b7];"
    BFILTER+="[b7]fade=t=in:st=0:d=0.5,fade=t=out:st=${fade_out_start}:d=0.6[final]"

    ffmpeg \
    -hide_banner \
    -loglevel warning \
    -loop 1 -t "$BUMPER_DURATION" -i overlay.png \
    -f lavfi -t "$BUMPER_DURATION" -i anullsrc=r=48000:cl=stereo \
    -filter_complex "$BFILTER" \
    -map "[final]" \
    -map 1:a \
    -r 24 \
    -s 1280x720 \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -threads 2 \
    -profile:v high \
    -level 4.1 \
    -pix_fmt yuv420p \
    -b:v 3000k \
    -maxrate 3000k \
    -bufsize 6000k \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -f flv \
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || echo "WARNING: bumper failed, continuing"
}

#############################################
# Stream one video
#############################################
run_video() {
    local url="$1"
    local attempt=1

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$ASSET_DIR/stars_a.png" \
        -loop 1 -i "$ASSET_DIR/stars_b.png" \
        -loop 1 -i "$ASSET_DIR/stars_c.png" \
        -filter_complex "$FILTER" \
        -map "[final]" \
        -map 0:a? \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "✓ Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop (simple - no tagging)
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries"
    exit 1
fi

echo "✓ Loaded $NUM_URLS video(s)"
for ((i = 0; i < NUM_URLS; i++)); do
    echo "  [$((i+1))] ${URLS[$i]}"
done
echo ""

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"
        next_idx=$(( (i + 1) % NUM_URLS ))
        next_url="${URLS[$next_idx]}"

        run_video "$url"

        if [ "$ENABLE_BUMPER" = true ]; then
            run_bumper "$next_url"
        fi

        echo "Loading next video in 5 seconds..."
        sleep 5
    done
done
