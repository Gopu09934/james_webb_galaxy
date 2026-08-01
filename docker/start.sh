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

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those panel elements just stay blank instead of
# failing the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
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
CHANNEL_NAME="Technical Talk India"

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

#############################################
# Background subscriber-count writer
# (polls YouTube Data API every 60s — subs
# don't change second to second, and this
# respects API quota)
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
            if [ -n "$COUNT" ]; then
                # Manual comma insertion — locale-independent, so it works
                # the same regardless of the container's default locale
                # (printf "%'d" silently fails to group digits under the
                # bare "C" locale that Ubuntu containers ship with).
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                # Log the raw response once so it shows up in the Actions
                # log — this tells us exactly why the count isn't parsing
                # (bad channel ID, disabled API, quota, key restrictions, etc.)
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
# Strategy: find the channel's currently-live
# video once (search.list — costs more quota,
# so only called when we don't already have an
# id), then poll videos.list (cheap, 1 unit)
# every 30s for concurrentViewers. If the
# broadcast ends/restarts, re-search.
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
                if [ -n "$VIEWERS" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    # Broadcast ended or hasn't registered yet — clear and re-search.
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"
printf 'DEEP SPACE REPORT'                > "$ASSET_DIR/eyebrow.txt"

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

HEADLINE_Y=230
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
# Build the BASE filter chain (everything that
# does NOT depend on the current video's
# duration). The CTA / countdown / ticker /
# border / watermark section is appended later,
# per-video, in build_final_filter().
#############################################
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"

# --- base video + background art -------------------------------
CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base];"

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

# --- credits + live UTC clock + subscriber count + viewer count -----------
# Right-aligned to the panel's own right edge (313), stacked vertically.
CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=15:x=313-text_w:y=19[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=313-text_w:y=39[p10];"
CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=313-text_w:y=57[p10b];"
CHAIN+="[p10b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=313-text_w:y=75[p10c];"

# --- titles (with subtle drop shadow) --------------------------------------
# NOTE: shifted +12px down from the original y=83 baseline to clear the
# subs/viewers stat lines added above (which end around y=89-91).
CHAIN+="[p10c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=23:x=33:y=95:${SHADOW}[p11];"
CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=17:x=33:y=124:${SHADOW}[p12];"
CHAIN+="[p12]drawbox=x=33:y=155:w=280:h=2:color=white@0.3:t=fill[p13];"

# --- section header ----------------------------------------------------
CHAIN+="[p13]drawbox=x=33:y=171:w=8:h=8:color=${GOLD}:t=fill[p14];"
CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=15:x=49:y=168[p15];"

# --- eyebrow category tag above the rotating headline -----------------
CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=210[p16];"

prev="p16"
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    start=$((i * SLOT))
    end=$((start + SLOT))
    nxt="h${idx}"
    ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=33:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
    prev="$nxt"
done

# --- animated progress bar -----------------
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

# --- rotating fun fact ----------
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

BASE_CHAIN="$CHAIN"
FACT_END="$prev"

printf 'SUBSCRIBE for daily space discoveries' > "$ASSET_DIR/cta.txt"

#############################################
# build_final_filter: appends the CTA / next-
# video countdown / ticker / watermark / border
# section onto BASE_CHAIN. Called fresh for each
# video since the countdown depends on that
# video's probed duration.
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    # --- CTA box: alternates between "SUBSCRIBE" (8s every 4 min) and a
    # live "Next video in Xs" countdown the rest of the time. -----------
    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    tail+="[${FACT_END}]drawbox=x=733:y=620:w=507:h=43:color=black@0.75:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=733:y=620:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next video in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        # Duration unknown (e.g. ffprobe couldn't read it) — generic filler.
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    # --- bottom ticker bar -------------------------------------------------
    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.85:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=16:x=17:y=695[tk6];"

    # --- watermark: channel name, low-opacity, bottom-left ---------------
    # NOTE: moved from bottom-right to bottom-left — YouTube's own native
    # subscribe-bell overlay tends to render bottom-right, which collided
    # with this text.
    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.35:fontsize=15:x=353:y=655[wm1];"

    # --- outer frame border -------------------------------------------------
    tail+="[wm1]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

    echo "$tail"
}

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
    BFILTER+="[b5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_title.txt:fontcolor=white:fontsize=36:line_spacing=8:x=(w-text_w)/2:y=347:${SHADOW}[b6];"
    BFILTER+="[b6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_sub.txt:fontcolor=white@0.75:fontsize=18:x=(w-text_w)/2:y=427[b7];"
    BFILTER+="[b7]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.4:fontsize=14:x=(w-text_w)/2:y=470[b8];"
    BFILTER+="[b8]fade=t=in:st=0:d=0.5,fade=t=out:st=${fade_out_start}:d=0.6[final]"

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
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    # Probe actual duration so the CTA box can show a real countdown to
    # the next video. Falls back gracefully if probing fails (e.g. some
    # live/streamed sources report no duration).
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
    duration=${duration%.*}
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
    if [ -n "$duration" ]; then
        echo "Probed duration: ${duration}s"
    else
        echo "Could not probe duration — countdown will show generic filler text."
    fi

    local filter
    filter=$(build_final_filter "$duration")

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
        -filter_complex "$filter" \
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
# Stream loop
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
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi
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
        echo ""
        sleep 5
    done
done
