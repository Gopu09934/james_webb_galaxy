#!/bin/bash
set -euo pipefail

if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

echo "========================================"
echo "Stream with Twinkling Stars (Low Lag)"
echo "Video + Overlay + Ticker + Twinkling Stars"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
ASSET_DIR="panel_assets"
TICKER_SPEED=110

mkdir -p "$ASSET_DIR"

#############################################
# Generate SPARSE twinkling stars
# Very reduced count for performance
#############################################
python3 - "$ASSET_DIR" <<'PYEOF'
import random, sys
from PIL import Image, ImageDraw

out_dir = sys.argv[1]
W, H = 1280, 720
random.seed(7)

def make_star_layer(path, count):
    """Create sparse star layer"""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x = random.randint(0, W - 1)
        y = random.randint(0, H - 1)
        r = random.choice([1, 2])  # 1px or 2px stars
        base_a = random.randint(150, 255)
        color = (255, 255, 255, base_a)
        if r == 1:
            d.point((x, y), fill=color)
        else:
            d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    img.save(path)

# SPARSE star counts: 20, 15, 10 = 45 total (90% reduction from 420)
# This gives scattered stars but keeps performance high
make_star_layer(f"{out_dir}/stars_a.png", 20)
make_star_layer(f"{out_dir}/stars_b.png", 15)
make_star_layer(f"{out_dir}/stars_c.png", 10)
print("✓ Generated 3 twinkling star layers (45 stars total, sparse)")
PYEOF

# Clock in background
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

# Simple ticker text
if [ ! -f "$ASSET_DIR/ticker.txt" ]; then
    printf 'JAMES WEBB SPACE TELESCOPE • Deep Space Live Stream • 4K • NASA • Cosmic Discoveries' > "$ASSET_DIR/ticker.txt"
fi

MAX_RETRIES=5
RETRY_DELAY=5

run_video() {
    local url="$1"
    local attempt=1

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}): ${url##*/}"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel warning \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$ASSET_DIR/stars_a.png" \
        -loop 1 -i "$ASSET_DIR/stars_b.png" \
        -loop 1 -i "$ASSET_DIR/stars_c.png" \
        -filter_complex "[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[v];[1:v]scale=1280:720[ovl];[2:v]scale=1280:720[star_a_src];[3:v]scale=1280:720[star_b_src];[4:v]scale=1280:720[star_c_src];[v][ovl]overlay=0:0[base];[base][star_a_src]overlay=0:0:alpha=0.30[with_a];[with_a][star_b_src]overlay=0:0:alpha=0.22[with_b];[with_b][star_c_src]overlay=0:0:alpha=0.15[video];[video]drawbox=x=0:y=680:w=1280:h=40:color=black@0.75:t=fill[tk1];[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.8:t=fill[tk2];[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=16:y=692:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];[tk3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=12:x=10:y=690[final]" \
        -map "[final]" \
        -map 0:a? \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -pix_fmt yuv420p \
        -b:v 2800k \
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
            echo "✓ Video finished."
            return 0
        fi

        echo "WARNING: Exit code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})"
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
    done
    return 1
}

#############################################
# Simple loop
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
    echo "ERROR: No valid videos in VIDEO_URL"
    exit 1
fi

echo "✓ Loaded $NUM_URLS video(s)"
echo "✓ Stars: Sparse + Twinkling (45 stars total)"
echo "  Layer A: 20 stars, twinkles at 2Hz"
echo "  Layer B: 15 stars, twinkles at 1.5Hz (offset)"
echo "  Layer C: 10 stars, twinkles at 1Hz (offset)"
echo ""
while true; do
    for url in "${URLS[@]}"; do
        run_video "$url"
        sleep 2
    done
done
