#!/bin/bash
#############################################
# MARS 2020 PERSEVERANCE ROVER - LIVE STREAM  (v2: gap-free)
#
# Architecture (why the old version dropped every 2 min):
#   OLD : ffmpeg ran for one 120s batch, exited, the script then
#         downloaded images / rebuilt assets, and only then reconnected
#         to YouTube -> a disconnect + reconnect every cycle.
#   NEW : three long-lived parts
#         1. RENDERER  - builds the next 120s batch into an MPEG-TS
#                        segment file, always staying ~2 segments ahead.
#         2. FEEDER    - copies finished segments, in order, into a pipe.
#         3. PUBLISHER - ONE ffmpeg (-c copy, almost no CPU) that reads the
#                        pipe and stays connected to YouTube. If it dies it
#                        is restarted with back-off; the buffer keeps going.
#   Slow downloads / NASA API errors / a failed render can no longer
#   interrupt the live connection.
#
# Same look as before: Front Hazcam Left/Right only, Ken Burns + xfade,
# trapezoid panels, ticker, facts, status, looping background music.
#
# Optional env: YOUTUBE_STREAM_KEY (required), MUSIC_URL, YOUTUBE_API_KEY,
#   YOUTUBE_CHANNEL_ID, PRESET (default veryfast; use ultrafast on a weak
#   CPU), OUTPUT_URL (override target, used for testing).
#############################################
set -uo pipefail

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

#############################################
# Environment
#############################################
if [ -z "${OUTPUT_URL:-}" ]; then
    if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
        echo "ERROR: YOUTUBE_STREAM_KEY is not set"
        exit 1
    fi
    OUTPUT_URL="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
    OUTPUT_DESC="YouTube RTMP (key hidden)"
else
    OUTPUT_DESC="$OUTPUT_URL"
fi

SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set - subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

for tool in ffmpeg ffprobe jq curl mkfifo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' is required but not installed."; exit 1; }
done

#############################################
# Config
#############################################
FONT="${FONT:-font.ttf}"
if [ ! -f "$FONT" ]; then
    for f in /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
             /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
             /usr/share/fonts/TTF/DejaVuSans.ttf; do
        [ -f "$f" ] && { FONT="$f"; break; }
    done
fi
[ -f "$FONT" ] || { echo "ERROR: font file not found (put font.ttf next to the script)"; exit 1; }

GOLD="0xE8A33D"
RED="0xE8453C"
MARS_RED="0xC1440E"
ASSET_DIR="panel_assets"
IMAGES_DIR="mars_images"
SEG_DIR="segments"
STATE_DIR="state"
FIFO="$STATE_DIR/pipe.ts"

SLIDE_DURATION="${SLIDE_DURATION:-12}"
MAX_IMAGES="${MAX_IMAGES:-10}"
SEG_DUR=$((SLIDE_DURATION * MAX_IMAGES))      # every segment is exactly this long
FACT_SLOT=10
STATUS_SLOT=15
TICKER_SPEED=100
CHANNEL_NAME="Technical Talk india"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"

PAGE_SIZE=100
MAX_FETCH_PAGES=80
COLOR_TARGET=250
VIEWER_MIN_TO_SHOW=10

COLOR_CAMERAS=(
    "FRONT_HAZCAM_LEFT_A"
    "FRONT_HAZCAM_RIGHT_A"
    "FRONT_HAZCAM_LEFT_B"
    "FRONT_HAZCAM_RIGHT_B"
)

SUB_ICON_X=1249
SUB_ICON_Y=677
SUB_ICON_R=20

# Encoding
PRESET="${PRESET:-veryfast}"
READY_MAX="${READY_MAX:-3}"          # segments on disk (1 playing + 2 queued)
TS_WRAP="${TS_WRAP:-86400}"          # timestamp reset period (s), multiple of SEG_DUR
FIRST_DELAY="${FIRST_DELAY:-45}"     # guess: seconds until first segment starts playing

# Ken Burns / transitions
ZOOM_FPS=30
XFADE_DUR=1
ZOOM_MAX=1.5
ZOOM_STEP=0.0015
KB_SCALE_W=1400
KB_SCALE_H=788
TRANSITIONS=(fade dissolve wipeleft wiperight slideleft slideright smoothleft smoothright)

# Telemetry
LANDING_DATE_EPOCH=$(date -u -d '2021-02-18' +%s 2>/dev/null || echo 1613606400)
ROVER_LAT="18.4446"
ROVER_LON="77.4509"

# Music
MUSIC_URL="${MUSIC_URL:-}"
MUSIC_FILE="$ASSET_DIR/bgm_audio"
HAVE_MUSIC=false
MUSIC_DURATION=0

PANEL_PNG="$ASSET_DIR/panels.png"
START_EPOCH=$(date +%s)

mkdir -p "$ASSET_DIR" "$IMAGES_DIR" "$SEG_DIR" "$STATE_DIR"

echo "========================================"
echo "Mars 2020 Perseverance Rover Stream (gap-free)"
echo "Cameras  : Front Hazcam Left / Right"
echo "Output   : 1280x720 @ 30fps, preset=${PRESET}"
echo "Target   : ${OUTPUT_DESC}"
echo "Segments : ${MAX_IMAGES} slides x ${SLIDE_DURATION}s = ${SEG_DUR}s each"
echo "========================================"

#############################################
# Content pools
#############################################
MARS_FACTS=(
    "Mars is the fourth planet from the Sun and is known as the Red Planet."
    "A Martian day (Sol) is 24 hours, 39 minutes, and 35 seconds long."
    "Mars has two small moons: Phobos and Deimos."
    "The Perseverance rover landed in Jezero Crater on February 18, 2021."
    "Jezero Crater is believed to be an ancient lake bed billions of years old."
    "Mars has the largest volcano in the solar system: Olympus Mons, 21 km tall."
    "Valles Marineris on Mars is a canyon system over 4,000 km long."
    "Mars has a thin atmosphere composed mostly of carbon dioxide (95%)."
    "Perseverance has 19 cameras for science, engineering, and navigation."
    "Perseverance is searching for signs of ancient microbial life on Mars."
    "The MOXIE instrument on Perseverance converts CO2 into oxygen on Mars."
    "Mars is about half the size of Earth with a diameter of 6,779 km."
    "A Martian year lasts about 687 Earth days."
    "Mars has polar ice caps made of water ice and dry ice (CO2)."
    "The average distance from Earth to Mars is about 225 million km."
    "Radio signals from Mars take between 3 and 22 minutes to reach Earth."
    "NASA's Mars Reconnaissance Orbiter has been studying Mars since 2006."
    "Mars dust storms can sometimes engulf the entire planet for weeks or months."
    "Ancient Mars may have had liquid water rivers, lakes, and possibly an ocean."
    "The rover can travel up to 200 meters per Martian day across the surface."
    "Mastcam-Z on Perseverance can zoom in on objects hundreds of meters away."
    "Mars has the same land surface area as Earth - there are no oceans."
    "The first successful Mars rover was Sojourner, which landed in 1997."
    "Opportunity rover operated for 15 years on Mars, far beyond its 90-day mission."
    "Curiosity rover has been exploring Gale Crater since August 2012."
    "RIMFAX radar on Perseverance can peer up to 10 meters below the Martian surface."
    "Scientists study Mars to understand the history of water in our solar system."
    "Mars missions help us plan for future human exploration of the Red Planet."
    "Hazcams help Perseverance spot rocks and hazards right in front of its wheels."
)

MARS_HEADLINES=(
    "Perseverance rover exploring ancient Jezero Crater on Mars."
    "Scientists analyze Martian rock samples collected by Perseverance."
    "Ingenuity helicopter continues aerial reconnaissance of the Martian surface."
    "NASA's Perseverance searches for signs of ancient microbial life."
    "Perseverance collects pristine rock cores from the Martian lakebed."
    "Mars 2020 mission reveals secrets of Jezero Crater's ancient lake."
    "Perseverance rover captures stunning views of the Red Planet's terrain."
    "New Mars data challenges our understanding of early planetary evolution."
    "MOXIE demonstrates oxygen production from the thin Martian atmosphere."
    "Scientists map subsurface layers of Mars using RIMFAX ground-penetrating radar."
    "Mars sample return mission will bring Perseverance's cores back to Earth."
    "Perseverance's SuperCam laser vaporizes rocks to study their chemistry."
    "Dust devils and wind patterns reveal Martian atmospheric dynamics."
    "Ancient delta deposits in Jezero hint at a watery Martian past."
    "Perseverance teams up with Ingenuity for coordinated surface exploration."
)

ROVER_STATUSES=(
    "ACTIVE - EXPLORING"
    "ACTIVE - DRIVING"
    "ACTIVE - SAMPLING ROCK CORE"
    "ACTIVE - IMAGING TERRAIN"
    "ACTIVE - TRANSMITTING DATA"
    "ACTIVE - ANALYZING SPECTRA"
)

#############################################
# Trapezoid panel image (generated once)
#############################################
generate_panel_shapes() {
    log "Generating trapezoid panel image: $PANEL_PNG"

    _panel_shape() {
        local d="$1"
        echo "(lt(Y,134-${d})*gt(X,270+70*Y/134+${d})*lt(X,1010-70*Y/134-${d})+gte(Y,632+${d})*gt(X,470-80*(Y-632)/88+${d})*lt(X,810+80*(Y-632)/88-${d}))"
    }

    local OUTER INNER
    OUTER=$(_panel_shape 0)
    INNER=$(_panel_shape 3)

    ffmpeg -nostdin -y -hide_banner -loglevel error \
        -f lavfi -i "color=c=black:s=1280x720:r=1:d=1" \
        -vf "format=rgba,geq=r='if(${INNER},5,193)':g='if(${INNER},8,68)':b='if(${INNER},12,14)':a='if(${OUTER},if(${INNER},205,255),0)',format=rgba" \
        -frames:v 1 -update 1 "$PANEL_PNG"

    if [ ! -s "$PANEL_PNG" ]; then
        echo "ERROR: failed to generate $PANEL_PNG"
        exit 1
    fi
}

#############################################
# Background music (downloaded once)
#############################################
prepare_music() {
    if [ -z "$MUSIC_URL" ]; then
        echo "NOTICE: MUSIC_URL not set - streaming with silent audio track."
        return
    fi
    log "Downloading background music..."
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        if curl -sSL --max-time 120 -o "$MUSIC_FILE" "$MUSIC_URL"; then
            if [ -s "$MUSIC_FILE" ] && ffprobe -v error -select_streams a:0 \
                -show_entries stream=codec_type -of csv=p=0 "$MUSIC_FILE" 2>/dev/null | grep -q audio; then
                HAVE_MUSIC=true
                MUSIC_DURATION=$(ffprobe -v error -show_entries format=duration \
                    -of csv=p=0 "$MUSIC_FILE" 2>/dev/null | cut -d. -f1)
                MUSIC_DURATION="${MUSIC_DURATION:-0}"
                [[ "$MUSIC_DURATION" =~ ^[0-9]+$ ]] || MUSIC_DURATION=0
                log "Music OK: ${MUSIC_DURATION}s, loops seamlessly across segments"
                return
            fi
        fi
        log "Music download/validation failed (attempt ${attempt}/3)"
        rm -f "$MUSIC_FILE"
        attempt=$((attempt + 1))
        sleep 3
    done
    echo "WARNING: could not fetch valid audio - using silent audio."
    HAVE_MUSIC=false
}

#############################################
# NASA image list (kept in memory by the renderer)
#############################################
ALL_URL=(); ALL_CAM=(); ALL_DATE=(); ALL_SOL=()
OFFSET=0
TOTAL=0

fetch_image_list() {
    log "Fetching recent Front Hazcam image list..."
    local cams_json
    cams_json=$(printf '%s\n' "${COLOR_CAMERAS[@]}" | jq -R . | jq -s -c .)
    local base="https://mars.nasa.gov/rss/api/?feed=raw_images&category=mars2020&feedtype=json&order=sol%20desc"

    local rows="" page=0 raw=0 found=0
    while [ "$page" -lt "$MAX_FETCH_PAGES" ] && [ "$found" -lt "$COLOR_TARGET" ]; do
        local resp batch_count pr
        resp=$(curl -sSL --max-time 60 --retry 3 --retry-delay 5 \
            -H "Accept: application/json" -A "MarsLiveStream/1.0" \
            "${base}&num=${PAGE_SIZE}&page=${page}" 2>/dev/null) || true

        batch_count=$(printf '%s' "$resp" | jq '.images | length' 2>/dev/null) || batch_count=0
        [[ "${batch_count:-}" =~ ^[0-9]+$ ]] || batch_count=0
        [ "$batch_count" -eq 0 ] && break
        raw=$((raw + batch_count))

        # one row per frame: url|instrument|date|sol  (single jq call = fields stay aligned)
        pr=$(printf '%s' "$resp" | jq -r --argjson c "$cams_json" '
            .images[]
            | select(.camera.instrument as $i | $c | index($i))
            | [ (.image_files.large // .image_files.medium // ""),
                (.camera.instrument // ""),
                (.date_taken_utc // ""),
                ((.sol // "") | tostring) ]
            | join("|")' 2>/dev/null) || pr=""
        if [ -n "$pr" ]; then
            rows+="$pr"$'\n'
            found=$(printf '%s' "$rows" | grep -c . || true)
        fi

        [ "$batch_count" -lt "$PAGE_SIZE" ] && break
        page=$((page + 1))
        sleep 0.3
    done

    local n_url=() n_cam=() n_date=() n_sol=() u c d s
    while IFS='|' read -r u c d s; do
        [ -n "$u" ] || continue
        n_url+=("$u"); n_cam+=("$c"); n_date+=("$d"); n_sol+=("$s")
    done <<< "$rows"

    log "Hazcam fetch: ${#n_url[@]} Front Hazcam frames (scanned ${raw} raw frames)"
    [ "${#n_url[@]}" -gt 0 ] || return 1

    # replace the old list only on success
    ALL_URL=("${n_url[@]}"); ALL_CAM=("${n_cam[@]}")
    ALL_DATE=("${n_date[@]}"); ALL_SOL=("${n_sol[@]}")
    TOTAL=${#ALL_URL[@]}
    return 0
}

# Make sure OFFSET points into a valid list (re-fetching when exhausted).
prepare_batch() {
    if [ "$TOTAL" -eq 0 ] || [ "$OFFSET" -ge "$TOTAL" ]; then
        if fetch_image_list; then
            OFFSET=0
        else
            if [ "$TOTAL" -eq 0 ]; then
                log "ERROR: no image list available yet"
                return 1
            fi
            log "WARNING: refresh failed - replaying the existing list"
            OFFSET=0
        fi
    fi
    return 0
}

#############################################
# Download + validate one batch
#   fills SLIDE_* (always MAX_IMAGES long)
#############################################
G_FILE=(); G_CAM=(); G_DATE=(); G_SOL=(); G_FRAME=()    # last good batch
SLIDE_FILE=(); SLIDE_CAM=(); SLIDE_DATE=(); SLIDE_SOL=(); SLIDE_FRAME=()

download_batch() {
    local k="$1"
    local dir="$IMAGES_DIR/set_$(printf '%06d' "$k")"
    rm -rf "$dir"; mkdir -p "$dir"

    local V_FILE=() V_CAM=() V_DATE=() V_SOL=() V_FRAME=()
    local i gi url out http_code magic rejected=0
    for ((i = 0; i < MAX_IMAGES; i++)); do
        gi=$((OFFSET + i))
        [ "$gi" -ge "$TOTAL" ] && break
        url="${ALL_URL[$gi]}"
        out="$dir/img_$(printf '%03d' "$i").jpg"

        http_code=$(curl -sL --max-time 30 -o "$out" -w '%{http_code}' "$url" 2>/dev/null || echo "000")
        if [ "$http_code" != "200" ] || [ ! -s "$out" ]; then
            rm -f "$out"; rejected=$((rejected + 1)); continue
        fi
        magic=$(head -c 2 "$out" 2>/dev/null | od -An -tx1 | tr -d ' \n')
        if [[ "$magic" != "ffd8"* ]]; then
            rm -f "$out"; rejected=$((rejected + 1)); continue
        fi
        if ! ffprobe -v error -select_streams v:0 -show_entries stream=width \
                -of csv=p=0 "$out" >/dev/null 2>&1; then
            rm -f "$out"; rejected=$((rejected + 1)); continue
        fi
        V_FILE+=("$out"); V_CAM+=("${ALL_CAM[$gi]}"); V_DATE+=("${ALL_DATE[$gi]}")
        V_SOL+=("${ALL_SOL[$gi]}"); V_FRAME+=("$((gi + 1))")
    done
    log "Download: ${#V_FILE[@]} valid, ${rejected} rejected (frames $((OFFSET + 1))-$((OFFSET + i)) of ${TOTAL})"

    if [ "${#V_FILE[@]}" -gt 0 ]; then
        G_FILE=("${V_FILE[@]}"); G_CAM=("${V_CAM[@]}"); G_DATE=("${V_DATE[@]}")
        G_SOL=("${V_SOL[@]}"); G_FRAME=("${V_FRAME[@]}")
        # drop older image sets, keep only this one
        local d
        for d in "$IMAGES_DIR"/set_*; do
            [ "$d" = "$dir" ] || rm -rf "$d"
        done
    else
        rm -rf "$dir"
        if [ "${#G_FILE[@]}" -eq 0 ]; then
            log "ERROR: no valid images and nothing to fall back on"
            return 1
        fi
        log "WARNING: all downloads failed - reusing the previous image set"
        V_FILE=("${G_FILE[@]}"); V_CAM=("${G_CAM[@]}"); V_DATE=("${G_DATE[@]}")
        V_SOL=("${G_SOL[@]}"); V_FRAME=("${G_FRAME[@]}")
    fi

    # Always exactly MAX_IMAGES slides so every segment is exactly SEG_DUR long
    SLIDE_FILE=(); SLIDE_CAM=(); SLIDE_DATE=(); SLIDE_SOL=(); SLIDE_FRAME=()
    local n=${#V_FILE[@]} j
    for ((i = 0; i < MAX_IMAGES; i++)); do
        j=$((i % n))
        SLIDE_FILE+=("${V_FILE[$j]}"); SLIDE_CAM+=("${V_CAM[$j]}"); SLIDE_DATE+=("${V_DATE[$j]}")
        SLIDE_SOL+=("${V_SOL[$j]}"); SLIDE_FRAME+=("${V_FRAME[$j]}")
    done
    return 0
}

#############################################
# Text assets for one segment
#############################################
write_segment_assets() {
    local k="$1"
    CURRENT_SOL="${SLIDE_SOL[0]:-0}"
    [[ "$CURRENT_SOL" =~ ^[0-9]+$ ]] || CURRENT_SOL=0

    # telemetry (deterministic per sol)
    local seed=$((CURRENT_SOL + 1000))
    RANDOM=$seed;           local temp_high=$(( -35 - (RANDOM % 20) ))
    RANDOM=$((seed + 1));   local wind=$(( 6 + (RANDOM % 24) ))
    RANDOM=$((seed + 2));   local pressure=$(( 640 + (RANDOM % 120) ))
    printf 'TEMP %s°C  •  WIND %s km/h  •  %s Pa' "$temp_high" "$wind" "$pressure" > "$ASSET_DIR/telem.txt"

    local now_epoch mission_days lat_short lon_short
    now_epoch=$(date -u +%s)
    mission_days=$(( (now_epoch - LANDING_DATE_EPOCH) / 86400 ))
    lat_short="${ROVER_LAT%??}"
    lon_short="${ROVER_LON%??}"
    printf 'SOL %s  •  %s days on Mars  •  %s°N %s°E' "$CURRENT_SOL" "$mission_days" "$lat_short" "$lon_short" > "$ASSET_DIR/timeonmars.txt"

    printf 'MARS 2020'                          > "$ASSET_DIR/title1.txt"
    printf 'P E R S E V E R A N C E  R O V E R' > "$ASSET_DIR/title2.txt"
    printf "SOL %s RAW IMAGERY" "$CURRENT_SOL"  > "$ASSET_DIR/header.txt"
    printf 'LIVE FROM THE RED PLANET'           > "$ASSET_DIR/eyebrow.txt"
    printf 'SUBSCRIBE for daily Mars updates'   > "$ASSET_DIR/cta.txt"
    printf 'Perseverance  •  Landed Feb 18, 2021  •  Jezero Crater  •  %s Hazcam frames' "$TOTAL" > "$ASSET_DIR/mission.txt"

    # facts / statuses rotate continuously across segments (no repeats within a cycle)
    FACT_SLOTS=$(( (SEG_DUR + FACT_SLOT - 1) / FACT_SLOT ))
    STATUS_SLOTS=$(( (SEG_DUR + STATUS_SLOT - 1) / STATUS_SLOT ))
    local i
    for ((i = 0; i < FACT_SLOTS; i++)); do
        printf 'MARS FACT:  %s' "${MARS_FACTS[$(( (k * FACT_SLOTS + i) % ${#MARS_FACTS[@]} ))]}" \
            > "$ASSET_DIR/fact$((i + 1)).txt"
    done
    for ((i = 0; i < STATUS_SLOTS; i++)); do
        printf 'STATUS: %s' "${ROVER_STATUSES[$(( (k * STATUS_SLOTS + i) % ${#ROVER_STATUSES[@]} ))]}" \
            > "$ASSET_DIR/status$((i + 1)).txt"
    done

    local ticker="" nh=${#MARS_HEADLINES[@]}
    for ((i = 0; i < nh; i++)); do
        ticker+="${MARS_HEADLINES[$(( (k * 3 + i) % nh ))]}     •     "
    done
    printf '%s' "$ticker" > "$ASSET_DIR/ticker.txt"

    # per-slide info boxes
    for ((i = 0; i < MAX_IMAGES; i++)); do
        local cam="${SLIDE_CAM[$i]:-Unknown Camera}"
        cam="${cam//_/ }"
        local edate="${SLIDE_DATE[$i]:-}"
        printf 'TRANSMISSION FROM MARS\nSol %s  ·  Frame %d of %d\n%s' \
            "${SLIDE_SOL[$i]:-$CURRENT_SOL}" "${SLIDE_FRAME[$i]}" "$TOTAL" "$cam" \
            > "$ASSET_DIR/slide_info$((i + 1)).txt"
        if [ -n "$edate" ]; then
            local es="${edate:0:16}"
            es="${es/T/ }"
            printf '\nEarth Date: %s UTC' "$es" >> "$ASSET_DIR/slide_info$((i + 1)).txt"
        fi
    done
}

#############################################
# Filter graph: Ken Burns slideshow
#############################################
build_slideshow_filter() {
    local n="$1" chain="" prev="" i
    for ((i = 0; i < n; i++)); do
        local dur=$SLIDE_DURATION
        [ "$i" -ne $((n - 1)) ] && dur=$((SLIDE_DURATION + XFADE_DUR))
        local frames=$((dur * ZOOM_FPS))

        local z x y
        case $((i % 4)) in
            0) z="min(zoom+${ZOOM_STEP}\,${ZOOM_MAX})"
               x="iw/2-(iw/zoom/2)"; y="ih/2-(ih/zoom/2)" ;;
            1) z="if(eq(on\,1)\,${ZOOM_MAX}\,max(1.001\,zoom-${ZOOM_STEP}))"
               x="iw/2-(iw/zoom/2)"; y="ih/2-(ih/zoom/2)" ;;
            2) z="min(zoom+${ZOOM_STEP}\,${ZOOM_MAX})"
               x="iw/2-(iw/zoom/2)+(on*0.35)"; y="ih/2-(ih/zoom/2)-(on*0.20)" ;;
            3) z="min(zoom+${ZOOM_STEP}\,${ZOOM_MAX})"
               x="iw/2-(iw/zoom/2)-(on*0.35)"; y="ih/2-(ih/zoom/2)+(on*0.20)" ;;
        esac

        # NOTE: images are single-frame inputs (no -loop 1): zoompan itself
        # expands each one into `frames` frames, so no CPU is wasted on
        # decoding the same JPEG hundreds of times.
        local label="img${i}"
        chain+="[${i}:v]scale=in_range=pc:out_range=tv,scale=${KB_SCALE_W}:${KB_SCALE_H}:force_original_aspect_ratio=increase,"
        chain+="crop=${KB_SCALE_W}:${KB_SCALE_H},"
        chain+="zoompan=z='${z}':x='${x}':y='${y}':d=${frames}:s=1280x720:fps=${ZOOM_FPS},"
        chain+="setpts=N/${ZOOM_FPS}/TB,format=yuv420p,setsar=1[${label}];"

        if [ "$i" -eq 0 ]; then
            prev="$label"
        else
            local transition="${TRANSITIONS[$(( (i - 1) % ${#TRANSITIONS[@]} ))]}"
            local offset=$((i * SLIDE_DURATION))
            chain+="[${prev}][${label}]xfade=transition=${transition}:duration=${XFADE_DUR}:offset=${offset}[xf${i}];"
            prev="xf${i}"
        fi
    done
    chain+="[${prev}]eq=brightness=0.06:contrast=1.18:saturation=1.15:gamma=1.04[slideshow];"
    SLIDESHOW_FILTER="$chain"
}

#############################################
# Filter graph: full overlay stack
#   $1 = slide count, $2 = panels input idx, $3 = epoch at which t=0 plays
#############################################
build_full_filter() {
    local n_slides="$1" PANEL_IDX="$2" PLAY_EPOCH="$3"
    local CTA_CYCLE=180 CTA_SHOW=8

    build_slideshow_filter "$n_slides"

    local F="$SLIDESHOW_FILTER"
    # panels.png is decoded once and cached by the loop filter
    F+="[${PANEL_IDX}:v]format=rgba,loop=loop=-1:size=1:start=0,setpts=N/${ZOOM_FPS}/TB[pnlimg];"
    F+="[slideshow][pnlimg]overlay=0:0:format=auto[base];"

    # ---- per-slide info (bottom-left) ----
    local prev="base" i
    for ((i = 0; i < n_slides; i++)); do
        local idx=$((i + 1)) start=$((i * SLIDE_DURATION))
        local end=$((start + SLIDE_DURATION))
        local EN="between(t\,${start}\,${end})"
        local AL="if(lt(t-${start}\,0.5)\,(t-${start})/0.5\,if(gt(t-${start}\,${SLIDE_DURATION}-0.5)\,(${end}-t)/0.5\,1))"
        F+="[${prev}]drawbox=x=20:y=560:w=350:h=118:color=black@0.55:t=fill:enable='${EN}'[sib${idx}];"
        F+="[sib${idx}]drawbox=x=20:y=560:w=4:h=118:color=${MARS_RED}:t=fill:enable='${EN}'[sil${idx}];"
        F+="[sil${idx}]drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/slide_info${idx}.txt:fontcolor=white:fontsize=15:line_spacing=7:x=40:y=572:alpha='${AL}':enable='${EN}':borderw=1.5:bordercolor=black@0.85:${SHADOW}[si${idx}];"
        prev="si${idx}"
    done

    local c=0
    add() { c=$((c + 1)); F+="[${prev}]$1[s${c}];"; prev="s${c}"; }

    # ================= TOP PANEL =================
    add "drawbox=x=297:y=16:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'"
    add "drawtext=fontfile=${FONT}:expansion=none:text='LIVE':fontcolor=white:fontsize=22:x=314:y=9"
    # Live UTC clock computed from the frame timestamp (works on pre-rendered video)
    add "drawtext=fontfile=${FONT}:expansion=normal:text='%{pts\:gmtime\:${PLAY_EPOCH}\:%d %b %Y  •  %T UTC}':fontcolor=${GOLD}:fontsize=12:x=314:y=62"

    add "drawtext=fontfile=${FONT}:expansion=none:text='Credits\: NASA/JPL-Caltech':fontcolor=white@0.85:fontsize=13:x=970-text_w:y=10"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/subs.txt:fontcolor=white@0.75:fontsize=12:x=958-text_w:y=30"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/viewers.txt:fontcolor=white@0.75:fontsize=12:x=955-text_w:y=48"
    add "drawtext=fontfile=${FONT}:expansion=none:text='${CHANNEL_NAME}':fontcolor=white@0.70:fontsize=14:borderw=1:bordercolor=black@0.75:x=950-text_w:y=68"

    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/title1.txt:fontcolor=${MARS_RED}:fontsize=26:x=(w-text_w)/2:y=6:${SHADOW}"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.90:fontsize=14:x=(w-text_w)/2:y=38:${SHADOW}"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=(w-text_w)/2:y=58"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${MARS_RED}@0.95:fontsize=11:x=(w-text_w)/2:y=77"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/mission.txt:fontcolor=white@0.80:fontsize=12:x=(w-text_w)/2:y=93"

    # Rotating Mars fact: one slot per FACT_SLOT seconds, only active inside its slot
    for ((i = 0; i < FACT_SLOTS; i++)); do
        local fs=$((i * FACT_SLOT)) fe=$((i * FACT_SLOT + FACT_SLOT))
        local FEN="between(t\,${fs}\,${fe})"
        local FAL="if(lt(t-${fs}\,0.5)\,(t-${fs})/0.5\,if(gt(t-${fs}\,${FACT_SLOT}-0.5)\,(${fe}-t)/0.5\,1))"
        add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/fact$((i + 1)).txt:fontcolor=white@0.90:fontsize=12:x=(w-text_w)/2:y=109:alpha='${FAL}':enable='${FEN}'"
    done

    # ================= BOTTOM PANEL =================
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/telem.txt:fontcolor=white@0.92:fontsize=12:x=(w-text_w)/2:y=640"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/timeonmars.txt:fontcolor=${GOLD}@0.95:fontsize=11:x=(w-text_w)/2:y=659"

    for ((i = 0; i < STATUS_SLOTS; i++)); do
        local ss=$((i * STATUS_SLOT)) se=$((i * STATUS_SLOT + STATUS_SLOT))
        local SEN="between(t\,${ss}\,${se})"
        local SAL="if(lt(t-${ss}\,0.4)\,(t-${ss})/0.4\,if(gt(t-${ss}\,${STATUS_SLOT}-0.4)\,(${se}-t)/0.4\,1))"
        add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/status$((i + 1)).txt:fontcolor=white@0.92:fontsize=11:x=(w-text_w)/2:y=676:alpha='${SAL}':enable='${SEN}'"
    done
    add "drawbox=x=500:y=678:w=8:h=8:color=0x3DDC84:t=fill:enable='lt(mod(t\,2)\,1.6)'"

    # News ticker (scrolls inside its own small strip)
    add "drawbox=x=428:y=696:w=78:h=20:color=${MARS_RED}:t=fill"
    add "drawtext=fontfile=${FONT}:expansion=none:text='MARS LIVE':fontcolor=white:fontsize=11:x=437:y=701"
    F+="color=c=black@0:s=330x24:r=30,format=rgba,drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=15:borderw=2:bordercolor=black@0.6:y=(h-text_h)/2:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tkr];"
    F+="[${prev}][tkr]overlay=512:694:format=auto[tkov];"
    prev="tkov"

    # Slide progress bar (a tiny animated strip; drawbox cannot animate its width)
    F+="color=c=black@0:s=590x3:r=30,format=rgba,geq=r=193:g=68:b=14:a='if(lt(X\,590*mod(T\,${SLIDE_DURATION})/${SLIDE_DURATION})\,255\,0)'[bar];"
    F+="[${prev}][bar]overlay=345:125:format=auto[barov];"
    prev="barov"
    add "drawbox=x=345:y=125:w=590:h=3:color=white@0.15:t=fill"   # drawn *under* the bar visually via alpha order below
    # (the faint track is drawn after the bar at low alpha - harmless, keeps the track visible)

    # ================= SUBSCRIBE CTA (bottom-right) =================
    local CTA_EN="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local CTA_AL="if(lt(mod(t\,${CTA_CYCLE})\,0.5)\,mod(t\,${CTA_CYCLE})/0.5\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.5)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.5\,1))"
    add "drawbox=x=880:y=640:w=390:h=43:color=black@0.75:t=fill"
    add "drawbox=x=880:y=640:w=4:h=43:color=${MARS_RED}:t=fill"
    add "drawbox=x=898:y=656:w=11:h=11:color=${RED}:t=fill:enable='${CTA_EN}'"
    add "drawtext=fontfile=${FONT}:expansion=none:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=16:x=917:y=654:alpha='${CTA_AL}':enable='${CTA_EN}'"
    add "drawtext=fontfile=${FONT}:expansion=none:text='Front Hazcam View - Perseverance':fontcolor=white@0.80:fontsize=16:x=898:y=654:enable='not(${CTA_EN})'"

    local ring_x=$((SUB_ICON_X - SUB_ICON_R)) ring_y=$((SUB_ICON_Y - SUB_ICON_R)) ring_d=$((SUB_ICON_R * 2))
    add "drawbox=x=${ring_x}:y=${ring_y}:w=${ring_d}:h=${ring_d}:color=${GOLD}@0.9:t=3:enable='lt(mod(t\,3)\,1)'"

    F+="[${prev}]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2,fps=30,format=yuv420p[final]"
    printf '%s' "$F"
}

#############################################
# When will segment $1 actually play? (for the on-screen clock)
#############################################
play_epoch_for() {
    local k="$1" fk fe
    if [ -s "$STATE_DIR/feeding" ] && read -r fk fe < "$STATE_DIR/feeding" 2>/dev/null && [ -n "${fe:-}" ]; then
        echo $(( fe + (k - fk) * SEG_DUR ))
    else
        echo $(( START_EPOCH + FIRST_DELAY + k * SEG_DUR ))
    fi
}

seg_path() { printf '%s/seg_%06d.ts' "$SEG_DIR" "$1"; }

#############################################
# Render ONE segment to a .ts file
#############################################
render_segment() {
    local k="$1"
    prepare_batch || return 1
    download_batch "$k" || return 1
    write_segment_assets "$k"

    local n=$MAX_IMAGES
    local PANEL_IDX=$n AUDIO_IDX=$((n + 1))
    local play_epoch
    play_epoch=$(play_epoch_for "$k")

    local filter_script="$ASSET_DIR/filter_complex.txt"
    build_full_filter "$n" "$PANEL_IDX" "$play_epoch" > "$filter_script"

    local INPUT_ARGS=() f
    for f in "${SLIDE_FILE[@]}"; do INPUT_ARGS+=(-i "$f"); done
    INPUT_ARGS+=(-i "$PANEL_PNG")

    local AUDIO_ARGS=()
    if [ "$HAVE_MUSIC" = true ]; then
        local seek=0
        [ "${MUSIC_DURATION:-0}" -gt 1 ] && seek=$(( (k * SEG_DUR) % MUSIC_DURATION ))
        AUDIO_ARGS=(-ss "$seek" -stream_loop -1 -i "$MUSIC_FILE")
    else
        AUDIO_ARGS=(-f lavfi -i anullsrc=r=48000:cl=stereo)
    fi

    # timestamps continue across segments so the publisher sees one endless stream
    local ts_off=$(( (k * SEG_DUR) % TS_WRAP ))
    local out tmp errf="$ASSET_DIR/render_err.txt"
    out=$(seg_path "$k")
    tmp="${out}.part"

    local attempt rc t0 secs
    for attempt in 1 2 3; do
        t0=$SECONDS
        ffmpeg -nostdin -y -hide_banner -loglevel error -nostats \
            "${INPUT_ARGS[@]}" "${AUDIO_ARGS[@]}" \
            -filter_complex_script "$filter_script" \
            -map "[final]" -map "${AUDIO_IDX}:a" \
            -c:v libx264 -preset "$PRESET" -profile:v high -level 4.1 -pix_fmt yuv420p \
            -b:v 3000k -maxrate 3000k -bufsize 6000k \
            -g 60 -keyint_min 60 -sc_threshold 0 -bf 0 \
            -c:a aac -b:a 128k -ar 48000 -ac 2 \
            -t "$SEG_DUR" -output_ts_offset "$ts_off" \
            -f mpegts "$tmp" 2>"$errf"
        rc=$?
        secs=$((SECONDS - t0))
        if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
            mv -f "$tmp" "$out"
            [ "$secs" -lt 1 ] && secs=1
            log "Rendered segment ${k} (sol ${CURRENT_SOL}) in ${secs}s = $((SEG_DUR * 10 / secs))/10 x realtime"
            if [ "$secs" -gt $((SEG_DUR * 9 / 10)) ]; then
                log "WARNING: renderer is too slow for real time. Set PRESET=ultrafast or close other CPU-heavy programs."
            fi
            return 0
        fi
        log "WARNING: render attempt ${attempt}/3 failed (exit ${rc}):"
        tail -n 5 "$errf" | sed 's/^/    /'
        rm -f "$tmp"
        sleep 2
    done
    return 1
}

#############################################
# RENDERER: keeps READY_MAX segments on disk
#############################################
render_loop() {
    local k=0
    [ -s "$STATE_DIR/render_k" ] && k=$(cat "$STATE_DIR/render_k")
    while true; do
        local pending
        pending=$(ls "$SEG_DIR"/seg_*.ts 2>/dev/null | wc -l | tr -d ' ')
        if [ "$pending" -ge "$READY_MAX" ]; then
            sleep 2
            continue
        fi
        if render_segment "$k"; then
            OFFSET=$((OFFSET + MAX_IMAGES))
            k=$((k + 1))
            echo "$k" > "$STATE_DIR/render_k"
        else
            log "Segment ${k} failed - retrying in 10s (stream keeps playing from buffer)"
            sleep 10
        fi
    done
}

#############################################
# FEEDER: segments -> pipe, strictly in order
#############################################
feeder_loop() {
    exec 3<>"$FIFO"          # read/write open: never blocks, never SIGPIPE
    local k=0 waited
    [ -s "$STATE_DIR/next_k" ] && k=$(cat "$STATE_DIR/next_k")
    while true; do
        local seg
        seg=$(seg_path "$k")
        waited=0
        while [ ! -s "$seg" ]; do
            sleep 0.5
            waited=$((waited + 1))
            if [ "$waited" -eq 20 ]; then
                log "WARNING: next segment ${k} not ready - the live stream will stall until it is (renderer too slow?)"
            fi
        done
        echo "$k $(date +%s)" > "$STATE_DIR/feeding.tmp" && mv -f "$STATE_DIR/feeding.tmp" "$STATE_DIR/feeding"
        cat "$seg" >&3
        rm -f "$seg"
        k=$((k + 1))
        echo "$k" > "$STATE_DIR/next_k"
    done
}

#############################################
# PUBLISHER: one ffmpeg, -c copy, stays connected
#############################################
run_publisher() {
    local TIMEOUT_ARGS=()
    case "$OUTPUT_URL" in rtmp*://*) TIMEOUT_ARGS=(-rw_timeout 20000000) ;; esac
    ffmpeg -nostdin -hide_banner -loglevel warning -stats -stats_period 60 \
        -re -probesize 500000 -analyzeduration 1000000 \
        -f mpegts -i "$FIFO" \
        -map 0:v:0 -map 0:a:0 -c copy \
        -flvflags no_duration_filesize \
        "${TIMEOUT_ARGS[@]}" \
        -f flv "$OUTPUT_URL"
}

publisher_loop() {
    local backoff=2 t0 rc elapsed
    while true; do
        log "Publisher: connecting to ${OUTPUT_DESC}"
        t0=$SECONDS
        run_publisher
        rc=$?
        elapsed=$((SECONDS - t0))
        if [ "$elapsed" -gt 60 ]; then backoff=2; else backoff=$((backoff * 2)); [ "$backoff" -gt 30 ] && backoff=30; fi
        log "WARNING: publisher exited (code ${rc}) after ${elapsed}s - reconnecting in ${backoff}s"
        sleep "$backoff"
    done
}

#############################################
# Background subscriber / viewer counters
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
printf ' ' > "$ASSET_DIR/viewers.txt"
SUBS_PID=""; VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s --max-time 20 "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+' || true)
            if [ -n "$COUNT" ]; then
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API"
                WARNED_ONCE=true
            fi
            sleep 120
        done
    ) &
    SUBS_PID=$!

    (
        # The YouTube *search* endpoint costs 100 quota units per call (daily
        # limit 10,000). The old loop re-searched every 30s and burned the whole
        # quota in under an hour. Now: search only when we have no video id, and
        # at most once per 10 minutes; counting viewers (1 unit) every 60s.
        LIVE_VIDEO_ID=""
        LAST_SEARCH=0
        while true; do
            NOW=$(date +%s)
            if [ -z "$LIVE_VIDEO_ID" ] && [ $((NOW - LAST_SEARCH)) -ge 600 ]; then
                LAST_SEARCH=$NOW
                SEARCH_RESP=$(curl -s --max-time 20 "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/' || true)
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s --max-time 20 "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*' || true)
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                    # no concurrentViewers field at all => stream ended, search again later
                    [ -z "$VIEWERS" ] && LIVE_VIDEO_ID=""
                fi
            fi
            sleep 60
        done
    ) &
    VIEWERS_PID=$!
fi

#############################################
# Process supervision + cleanup
#############################################
RENDER_PID=""; FEEDER_PID=""; PUB_PID=""

cleanup() {
    trap - EXIT INT TERM
    local p
    for p in $RENDER_PID $FEEDER_PID $PUB_PID $SUBS_PID $VIEWERS_PID; do
        [ -n "$p" ] || continue
        pkill -TERM -P "$p" 2>/dev/null || true
        kill "$p" 2>/dev/null || true
    done
    pkill -TERM -P $$ 2>/dev/null || true
    echo "Stream ended - cleaning up."
}
trap cleanup EXIT INT TERM

#############################################
# MAIN
#############################################
prepare_music
generate_panel_shapes

rm -f "$SEG_DIR"/* "$STATE_DIR"/* 2>/dev/null || true
rm -rf "$IMAGES_DIR"/set_* 2>/dev/null || true
mkfifo "$FIFO"

log "Starting renderer (first segment takes a little while)..."
render_loop & RENDER_PID=$!

# Don't connect to YouTube until there is something to send.
waited=0
until [ -s "$(seg_path 0)" ]; do
    sleep 1
    waited=$((waited + 1))
    [ $((waited % 30)) -eq 0 ] && log "Still preparing the first segment (${waited}s)..."
    kill -0 "$RENDER_PID" 2>/dev/null || { echo "ERROR: renderer died during startup"; exit 1; }
done
log "First segment ready after ${waited}s - going live"

feeder_loop & FEEDER_PID=$!
publisher_loop & PUB_PID=$!

# Watchdog: if any part ever dies, restart it. The others keep running.
while true; do
    sleep 5
    if ! kill -0 "$RENDER_PID" 2>/dev/null; then
        log "WARNING: renderer died - restarting"
        render_loop & RENDER_PID=$!
    fi
    if ! kill -0 "$FEEDER_PID" 2>/dev/null; then
        log "WARNING: feeder died - restarting"
        feeder_loop & FEEDER_PID=$!
    fi
    if ! kill -0 "$PUB_PID" 2>/dev/null; then
        log "WARNING: publisher supervisor died - restarting"
        publisher_loop & PUB_PID=$!
    fi
done
