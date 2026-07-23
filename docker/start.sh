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
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
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

#############################################
# Up-next bumper (shown between videos)
#############################################
ENABLE_BUMPER=true
BUMPER_DURATION=5   # seconds
BUMPER_MESSAGES=(
    "Stay tuned for more cosmic wonders"
    "Another journey through deep space is coming up"
    "More discoveries from the edge of the universe"
    "The story of the cosmos continues"
)

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Background clock writer (avoids fragile
# drawtext %{gmtime} expansion syntax)
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

# NOTE: eyebrow.txt is no longer written once here — it's now written
# fresh before every video (see stream loop at the bottom), so the tag
# ("GALAXY REPORT" / "NEBULA REPORT" / etc.) matches whatever is
# actually playing. This default is only a fallback in case something
# streams before the loop sets it.
printf 'DEEP SPACE REPORT' > "$ASSET_DIR/eyebrow.txt"

#############################################
# Generate a twinkling starfield (two layers,
# offset in phase) as static PNGs once at
# startup. Cheaper than any per-frame
# procedural noise filter, and looks like a
# real fixed star field rather than TV static.
#############################################
STAR_LAYERS_ENABLED=true
python3 - "$ASSET_DIR" <<'PYEOF'
import random, sys
from PIL import Image, ImageDraw

out_dir = sys.argv[1]
W, H = 1280, 720
random.seed(7)

def make_layer(path, count):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x = random.randint(0, W - 1)
        y = random.randint(0, H - 1)
        r = random.choice([1, 1, 1, 2])          # mostly tiny points, some bigger
        base_a = random.randint(120, 255)
        color = (255, 255, 255, base_a)
        if r == 1:
            d.point((x, y), fill=color)
        else:
            d.ellipse([x - r, y - r, x + r, y + r], fill=color)
    img.save(path)

make_layer(f"{out_dir}/stars_a.png", 140)
make_layer(f"{out_dir}/stars_b.png", 110)
PYEOF
echo "Generated twinkling star layers: $ASSET_DIR/stars_a.png, $ASSET_DIR/stars_b.png"

#############################################
# Load headlines from galaxy_info.txt
# (still used to build the bottom ticker text)
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
echo "Loaded $N headline(s) from $INFO_FILE — rotation cycle: ${CYCLE}s"

# Wrap each headline for the side panel.
# Panel text column is ~280px wide at fontsize 21, so 25 chars/line fits
# comfortably without clipping.
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
done

# --- figure out how tall the tallest wrapped headline is --------------
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
MAX_HEADLINE_LINES=1
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
    [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
done
echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

HEADLINE_Y=218
PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 12))
DOTS_Y=$((PROGRESS_Y + 20))
FACT_DIVIDER_Y=$((DOTS_Y + 40))
FACT_LABEL_Y=$((FACT_DIVIDER_Y + 14))
FACT_TEXT_Y=$((FACT_LABEL_Y + 20))

# Build one long ticker string for the bottom scroll bar
TICKER_STRING=""
for i in "${!RAW_LINES[@]}"; do
    TICKER_STRING+="${RAW_LINES[$i]}     •     "
done
printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

#############################################
# Fun facts (fills empty space + adds motion)
# Optional file: facts.txt, one fact per line.
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
    "The Great Red Spot on Jupiter is a massive storm that has lasted for centuries."
    "Earth is the only known planet with liquid water on its surface."
    "The Moon is moving away from Earth by about 3.8 centimeters every year."
    "Mercury is the closest planet to the Sun and has extreme temperature changes."
    "Venus is the hottest planet in the solar system because of its thick carbon dioxide atmosphere."
    "Uranus rotates on its side, likely due to a massive ancient collision."
    "Neptune has the fastest winds recorded on any planet in the solar system."
    "The asteroid belt lies between Mars and Jupiter and contains millions of rocky objects."
    "Comets are made of ice, dust, and rocky material left over from the formation of the solar system."
    "The International Space Station orbits Earth at roughly 400 kilometers above the surface."
    "Space is not completely empty; it contains gas, dust, radiation, and tiny particles."
    "The first human to walk on the Moon was Neil Armstrong in 1969."
    "The Hubble Space Telescope has captured images of galaxies billions of light-years away."
    "Dark matter cannot be seen directly but its gravity affects galaxies and cosmic structures."
    "Dark energy is believed to be responsible for the accelerating expansion of the Universe."
    "The Milky Way and Andromeda galaxies are expected to merge in several billion years."
    "A supernova is the powerful explosion of a dying star."
    "The core of the Sun reaches temperatures of about 15 million degrees Celsius."
    "The closest star to Earth after the Sun is Proxima Centauri."
    "Some exoplanets orbit stars outside our solar system and may have conditions suitable for life."
    "The largest known structures in the Universe are galaxy clusters and cosmic filaments."
    "Time moves differently near extremely strong gravitational fields, according to Einstein's relativity."
    "The Voyager spacecraft have traveled farther from Earth than any other human-made objects."
    "Earth's magnetic field protects the planet from harmful solar radiation."
    "Auroras are created when charged particles from the Sun interact with Earth's atmosphere."
    "The Milky Way has a supermassive black hole at its center called Sagittarius A*."
    "The observable Universe contains billions of galaxies."
    "Some stars are hundreds of times larger than the Sun."
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
# Build the filter_complex dynamically
#############################################

# --- base video + background art -------------------------------
CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base0];"

# --- star overlay at fixed opacity --------------------------------
# Two star PNGs (inputs 2 and 3) overlaid at moderate opacity.
# Simple, clean, no per-frame expression issues.
if [ "$STAR_LAYERS_ENABLED" = true ]; then
    CHAIN+="[2:v]scale=1280:720[star_a];"
    CHAIN+="[3:v]scale=1280:720[star_b];"
    CHAIN+="[base0][star_a]overlay=0:0:alpha=0.35[base1];"
    CHAIN+="[base1][star_b]overlay=0:0:alpha=0.25[base];"
else
    CHAIN+="[base0]null[base];"
fi

# --- left info panel with feathered (gradient-style) edge -----------------
CHAIN+="[base]drawbox=x=0:y=0:w=333:h=720:color=black@0.60:t=fill[p1];"
CHAIN+="[p1]drawbox=x=333:y=0:w=4:h=720:color=black@0.45:t=fill[p2];"
CHAIN+="[p2]drawbox=x=337:y=0:w=4:h=720:color=black@0.30:t=fill[p3];"
CHAIN+="[p3]drawbox=x=341:y=0:w=4:h=720:color=black@0.15:t=fill[p4];"
CHAIN+="[p4]drawbox=x=0:y=0:w=347:h=4:color=${GOLD}@0.9:t=fill[p5];"
CHAIN+="[p5]drawbox=x=345:y=0:w=2:h=720:color=${GOLD}@0.6:t=fill[p6];"

# --- LIVE indicator: steady label + blinking dot ---------------------------
CHAIN+="[p6]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p8];"

# --- credits + live UTC clock ----------------------------------------------
CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=15:x=313-text_w:y=19[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=313-text_w:y=39[p10];"

# --- titles ------------------------------------------------------------
CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=23:x=33:y=83[p11];"
CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=17:x=33:y=112[p12];"
CHAIN+="[p12]drawbox=x=33:y=143:w=280:h=2:color=white@0.3:t=fill[p13];"

# --- section header ----------------------------------------------------
CHAIN+="[p13]drawbox=x=33:y=159:w=8:h=8:color=${GOLD}:t=fill[p14];"
CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=15:x=49:y=156[p15];"

# --- eyebrow category tag above the rotating headline -----------------
# NOTE: reload=1 added — eyebrow.txt is now rewritten per-video (see
# stream loop) to reflect that video's tag (Galaxy / Nebula / etc).
CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:reload=1:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=198[p16];"

prev="p16"
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    start=$((i * SLOT))
    end=$((start + SLOT))
    nxt="h${idx}"
    ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=33:y=${HEADLINE_Y}:alpha='${ALPHA}'[${nxt}];"
    prev="$nxt"
done

# --- animated progress bar: fills across current headline's time slot -----
CHAIN+="[${prev}]drawbox=x=33:y=${PROGRESS_Y}:w=280:h=2:color=white@0.15:t=fill[pg1];"
CHAIN+="[pg1]drawbox=x=33:y=${PROGRESS_Y}:w='280*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
prev="pg2"

# --- background dots (dim) -------------------------------------------------
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((33 + i * 17))
    nxt="db${idx}"
    CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
    prev="$nxt"
done

# --- active dot (gold, toggled per slot) -----------------------------------
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

# --- rotating fun fact (fills empty space, adds periodic motion) ----------
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

prev="$prev"

# --- periodic subscribe CTA (fades in every 4 min for 8s) -----------------
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

# --- bottom ticker bar -------------------------------------------------
CHAIN+="[${prev}]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
CHAIN+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
CHAIN+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
CHAIN+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.85:t=fill[tk4];"
CHAIN+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
CHAIN+="[tk5]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=16:x=17:y=695[tk6];"

# --- on-screen content label badge (center-bottom) ----------------------
# Large badge that displays current content type (NEBULA, GALAXY, etc.)
# with gold glow box and fade animation. Reads from badge.txt which
# is updated by the tag watcher.
printf 'DEEP SPACE' > "$ASSET_DIR/badge.txt"

CHAIN+="[tk6]drawbox=x=300:y=540:w=680:h=140:color=black@0.70:t=fill[badge_bg];"
CHAIN+="[badge_bg]drawbox=x=305:y=545:w=670:h=130:color=${GOLD}@0.20:t=1[badge_border];"
CHAIN+="[badge_border]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/badge.txt:reload=1:fontcolor=${GOLD}:fontsize=52:fontweight=bold:x=(w-text_w)/2:y=565[final]"

FILTER="$CHAIN"

#############################################
# Up-next bumper: short branded title card
# streamed between videos to reduce drop-off
# at the loop/transition point.
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
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || echo "WARNING: bumper failed, continuing to next video"
}

#############################################
# Tag watcher: swap eyebrow label as video
# plays through its timeline (e.g. "0:Nebula|45:Galaxy|120:Star Cluster")
#############################################
start_tag_watcher() {
    local timeline="$1"
    local start_ts
    start_ts=$(date +%s)
    local last_label=""

    # Parse timeline like "0:Nebula|45:Galaxy|120:Star Cluster"
    IFS='|' read -ra ENTRIES <<< "$timeline"

    while true; do
        local elapsed=$(( $(date +%s) - start_ts ))
        local label=""
        
        # Find the most recent threshold we've crossed
        for entry in "${ENTRIES[@]}"; do
            local sec="${entry%%:*}"
            local lbl="${entry#*:}"
            if [[ "$sec" =~ ^[0-9]+$ ]] && [ "$elapsed" -ge "$sec" ]; then
                label="$lbl"
            fi
        done
        [ -z "$label" ] && label="Deep Space"

        # Only rewrite if label changed (reduce file I/O)
        if [ "$label" != "$last_label" ]; then
            local upper_label=$(echo "$label" | tr '[:lower:]' '[:upper:]')
            
            # Left panel eyebrow tag
            printf '%s REPORT' "$upper_label" > "$ASSET_DIR/eyebrow.txt"
            
            # On-screen center badge (just the label, no "REPORT")
            printf '%s' "$upper_label" > "$ASSET_DIR/badge.txt"
            
            echo "  [TAG SWITCH] $label (elapsed: ${elapsed}s)"
            last_label="$label"
        fi
        sleep 1
    done
}

#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local timeline="$2"
    local attempt=1

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        [ -n "$timeline" ] && echo "Timeline: $timeline"
        echo "----------------------------------------"

        # Start the tag watcher in background
        start_tag_watcher "$timeline" &
        local TAG_PID=$!
        trap "kill $TAG_PID 2>/dev/null || true" RETURN

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$ASSET_DIR/stars_a.png" \
        -loop 1 -i "$ASSET_DIR/stars_b.png" \
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
            echo "Video finished normally."
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
# Stream loop with timeline support
#############################################
# VIDEO_URL format:
#   Simple:     https://example.com/video.mp4
#   Timeline:   https://example.com/video.mp4::0:Nebula|45:Galaxy|120:Star
#
# Timeline format: "SEC1:LABEL1|SEC2:LABEL2|..."
#   At 0s: panel shows "NEBULA REPORT"
#   At 45s: panel switches to "GALAXY REPORT"
#   At 120s: panel switches to "STAR REPORT"
#
# This is still manual — you write the timeline; not live detection.
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
TIMELINES=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -z "$u" ] && continue
    
    timeline=""
    if [[ "$u" == *"::"* ]]; then
        timeline="${u##*::}"
        u="${u%%::*}"
    fi
    [ -z "$timeline" ] && timeline="0:Deep Space"
    
    URLS+=("$u")
    TIMELINES+=("$timeline")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

echo "Parsed $NUM_URLS video(s):"
for ((i = 0; i < NUM_URLS; i++)); do
    echo "  [$((i+1))] ${URLS[$i]}"
    echo "       Timeline: ${TIMELINES[$i]}"
done
echo ""

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"
        timeline="${TIMELINES[$i]}"
        next_idx=$(( (i + 1) % NUM_URLS ))
        next_url="${URLS[$next_idx]}"

        run_video "$url" "$timeline"

        if [ "$ENABLE_BUMPER" = true ]; then
            run_bumper "$next_url"
        fi

        echo "Loading next video in 5 seconds..."
        echo ""
        sleep 5
    done
done
