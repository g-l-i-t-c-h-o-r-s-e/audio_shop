#!/usr/bin/env bash

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function cleanup() {
    if [[ -z "${TMP_DIR}" ]]; then
        exit "$1"
    elif [[ ! "${TMP_DIR}" == "${SCRIPT_DIR}/tmp_audio_shop_"* ]]; then
        exit "$1"
    fi

    rm -rf "${TMP_DIR}"
    exit "$1"
}

# Ensure cleanup is called on script exit, interruption, or termination
trap 'cleanup 1' EXIT SIGINT SIGTERM

function printDependencies() {
    echo "Error: \"$1\" could not be found, but is required."
    echo ""
    echo "This script requires ffmpeg, Sox, and ImageMagick to be installed."
    echo "You can install them using your package manager. For example:"
    echo "  sudo apt-get install ffmpeg sox imagemagick"
    echo ""
    cleanup 1
}

function printEffects() {
    echo "Available Effects:"
    echo "  bass 5"
    echo "  echo 0.8 0.88 60 0.4"
    echo "  flanger 0 2 0 71 0.5 25 lin"
    echo "  hilbert -n 5001"
    echo "  loudness 6"
    echo "  norm 90"
    echo "  overdrive 17"
    echo "  phaser 0.8 0.74 3 0.7 0.5"
    echo "  phaser 0.8 0.74 3 0.4 0.5"
    echo "  pitch 2"
    echo "  riaa"
    echo "  sinc 20-4k"
    echo "  vol 10"
}

function printHelp() {
    echo "Usage: $ ./mangle.sh input_file output_file [effects] [options]"
    echo ""
    echo "This script interprets image or video data as sound,"
    echo "applies audio effects, and converts it back to an image or video."
    echo ""
    echo "Options:"
    echo "  --bits=X          Set audio sample size in bits (8, 16, 24). Default: 8"
    echo "  --blend=X         Blend the distorted video with the original video. Default: 0.5"
    echo "  --color-format=X  Color space/format (rgb24, yuv444p, yuyv422). Use 'ffmpeg -pix_fmts' for full list."
    echo "  --effects         Display available effects."
    echo "  --help            Display this help information."
    echo "  --res=WxH         Set output resolution (e.g., 1920x1080). Default: original resolution."
    echo ""
    printEffects
    echo ""
    echo "Examples:"
    echo "  $ ./mangle.sh input.jpg output.png vol 11"
    echo "  $ ./mangle.sh input.mp4 output.mp4 echo 0.8 0.88 60 0.4"
    echo "  $ ./mangle.sh input.mp4 output.mp4 pitch 5 --res=1280x720"
    echo "  $ ./mangle.sh input.mp4 output.mp4 pitch 5 --blend=0.75 --color-format=yuv444p --bits=8"
    echo ""
    echo "A full list of effects can be found here: http://sox.sourceforge.net/sox.html#EFFECTS"
    echo ""
    cleanup 1
}

function helpNeeded() {
    if [[ -z ${1+x} ]]; then
        echo -e "Error: Input file not provided!\n"
        printHelp
    elif [[ ! -f $1 ]]; then
        echo -e "Error: Input file '$1' not found!\n"
        printHelp
    fi

    if [[ -z ${2+x} ]]; then
        echo -e "Error: Output file not provided!\n"
        printHelp
    fi

    if [[ -z ${3+x} ]]; then
        echo -e "Error: No effect specified.\n"
        printHelp
    fi
}

function parseArgs() {
    # Default values
    BITS=8
    YUV_FMT=rgb24
    RES=""
    BLEND=""
    IMAGE_EFFECTS=""

    INPUT_FILE="$1"
    OUTPUT_FILE="$2"

    shift 2

    # Process options first
    while [[ $# -gt 0 ]]; do
        case $1 in
            --bits=*)
                BITS="${1#*=}"
                shift
                ;;
            --blend=*)
                BLEND="${1#*=}"
                shift
                ;;
            --color-format=*)
                YUV_FMT="${1#*=}"
                shift
                ;;
            --res=*)
                RES="${1#*=}"
                shift
                ;;
            --effects)
                printEffects
                cleanup 0
                ;;
            --help)
                printHelp
                ;;
            *)
                break
                ;;
        esac
    done

    # Remaining arguments are effects
    EFFECTS=()
    while [[ $# -gt 0 ]]; do
        EFFECTS+=("$1")
        shift
    done

    helpNeeded "$INPUT_FILE" "$OUTPUT_FILE" "${EFFECTS[0]}"

    export BITS
    export YUV_FMT
    export RES
    export BLEND
    export EFFECTS

    export S_TYPE="u$BITS"
}

function cmd() {
    OUTPUT=$(eval "$@" 2>&1)
    if (( $? )); then
        echo -e "\n----- ERROR -----"
        echo -e "\nCommand: $*\n"
        echo -e "Output:\n$OUTPUT"
        echo -e "\n----- ERROR -----"
        cleanup 1
    fi
    echo "$OUTPUT"
}

function cmdSilent() {
    OUTPUT=$(eval "$@" 2>&1)
    if (( $? )); then
        echo -e "\n----- ERROR -----"
        echo -e "\nCommand: $*\n"
        echo -e "Output:\n$OUTPUT"
        echo -e "\n----- ERROR -----"
        cleanup 1
    fi
}

function getResolution() {
    eval $(cmd ffprobe -v error -of flat=s=_ -select_streams v:0 -show_entries stream=height,width "$1")
    RES="${streams_stream_0_width}x${streams_stream_0_height}"
    echo "$RES"
}

function getFrames() {
    FRAMES=$(cmd ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$1")
    REGEXP_INTEGER='^[0-9]+$'
    if ! [[ $FRAMES =~ $REGEXP_INTEGER ]]; then
        echo ""
        return 0
    fi
    echo "-frames $FRAMES"
    return 0
}

function getAudio() {
    AUDIO=$(cmd ffprobe -i "$1" -show_streams -select_streams a -loglevel error)
    [[ $AUDIO = *[!\ ]* ]] && echo "-i $TMP_DIR/audio_out.${AUDIO_TYPE}"
}

# Function to get framerate
function getFramerate() {
    local input_file="$1"
    # Extract the raw framerate (e.g., "30000/1001")
    local framerate_raw
    framerate_raw=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file")
    
    if [[ -z "$framerate_raw" ]]; then
        echo "0"
        return
    fi

    # Convert fractional framerate to decimal
    local framerate_decimal
    framerate_decimal=$(awk -F'/' '{ 
        if ($2 != 0) 
            printf "%.6f", $1/$2; 
        else 
            print "0" 
    }' <<< "$framerate_raw")
    
    echo "$framerate_decimal"
}

# Function to check if input is GIF
function isGIF() {
    local input_file="$1"
    local format_name
    format_name=$(ffprobe -v error -select_streams v:0 -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "$input_file")
    if [[ "$format_name" == "gif" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to extract GIF frames and delays
function extractGIFFrames() {
    local input_file="$1"
    local tmp_dir="$2"

    echo "Extracting frames from GIF..."
    # Extract frames as individual PNG files
    magick "$input_file" "$tmp_dir/frame_%04d.png"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to extract frames from GIF."
        cleanup 1
    fi

    echo "Extracting frame delays..."
    # Extract frame delays (in centiseconds)
    magick identify -format "%T\n" "$input_file" > "$tmp_dir/delays.txt"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to extract frame delays."
        cleanup 1
    fi

    echo "Extracting loop count..."
    # Extract loop count (0 means infinite)
    local loop_count
    loop_count=$(magick identify -format "%[iterations]" "$input_file")
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to extract loop count."
        cleanup 1
    fi
    echo "$loop_count" > "$tmp_dir/loop_count.txt"
}

# Function to assemble GIF from frames and delays
function assembleGIF() {
    local frame_dir="$1"
    local output_file="$2"
    local tmp_dir="$3"

    echo "Reading frame delays..."
    # Read delays into an array
    mapfile -t delays < "$tmp_dir/delays.txt"

    echo "Reading loop count..."
    # Read loop count
    loop_count=$(cat "$tmp_dir/loop_count.txt")
    if [[ -z "$loop_count" ]]; then
        loop_count=0
    fi

    echo "Assembling GIF with original frame delays and loop count..."
    # Prepare a temporary frames list with delays
    local frame_files=("$frame_dir"/*.png)
    local frames_with_delays=()
    for i in "${!frame_files[@]}"; do
        frames_with_delays+=("-delay" "${delays[$i]}")
        frames_with_delays+=("${frame_files[$i]}")
    done

    # Assemble GIF with ImageMagick
    magick "${frames_with_delays[@]}" -loop "$loop_count" "$output_file"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to assemble GIF."
        cleanup 1
    fi
}

function checkDependencies() {
    for CMD in "$@"; do
        if ! type "$CMD" > /dev/null 2>&1; then
            printDependencies "$CMD"
        fi
    done
}

# Check for required dependencies (excluding gifsicle)
checkDependencies ffprobe ffmpeg sox tr magick

parseArgs "$@"

# Create a unique temporary directory within the script's directory
TMP_DIR=$(mktemp -d "${SCRIPT_DIR}/tmp_audio_shop_XXXXXX")
if [[ ! "$TMP_DIR" ]]; then
    echo "Error: Failed to create temporary directory."
    exit 1
fi

export TMP_DIR

AUDIO_TYPE="mp3"
RES=${RES:-"$(getResolution "$INPUT_FILE")"}
FRAMERATE=$(getFramerate "$INPUT_FILE")
VIDEO=${VIDEO:-"$(getFrames "$INPUT_FILE")"}
AUDIO=${AUDIO:-"$(getAudio "$INPUT_FILE")"}

echo "TMP_DIR:         $TMP_DIR"
echo "RES:             $RES"
echo "FRAMERATE:       $FRAMERATE"
echo "VIDEO:           $VIDEO"
echo "AUDIO:           $AUDIO"
echo "FFMPEG_IN_OPTS:  $(eval echo "$FFMPEG_IN_OPTS")"
echo "FFMPEG_OUT_OPTS: $(eval echo "$FFMPEG_OUT_OPTS")"
echo "SOX_OPTS:        $(eval echo "$SOX_OPTS")"

INPUT_FILE="$1"
OUTPUT_FILE="$2"

if isGIF "$INPUT_FILE"; then
    IS_GIF=1
else
    IS_GIF=0
fi

export IS_GIF

if [[ "$IS_GIF" -eq 1 ]]; then
    FRAME_DIR="$TMP_DIR/frames"
    mkdir -p "$FRAME_DIR"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create frames directory."
        cleanup 1
    fi
    echo "Processing as GIF..."

    echo "Extracting GIF frames and delays..."
    extractGIFFrames "$INPUT_FILE" "$FRAME_DIR"

    echo "Processing frames as images..."
    for frame in "$FRAME_DIR"/*.png; do
        # Example image processing; replace with actual effects
        # Ensure ImageMagick commands are correctly using 'magick'
        # You can add multiple effects as needed
        magick "$frame" -brightness-contrast 10x0 "$frame"
        if [[ $? -ne 0 ]]; then
            echo "Error: Failed to process frame $frame."
            cleanup 1
        fi
    done

    echo "Reassembling GIF..."
    assembleGIF "$FRAME_DIR" "$OUTPUT_FILE" "$TMP_DIR"

else
    echo "Processing as standard video/audio..."

    echo "Extracting raw image data..."
    cmdSilent "ffmpeg -y -i \"$INPUT_FILE\" -pix_fmt $YUV_FMT $FFMPEG_IN_OPTS \"$TMP_DIR/tmp.yuv\""

    if [[ $AUDIO = *[!\ ]* ]]; then
        echo "Extracting audio track..."
        cmdSilent "ffmpeg -y -i \"$INPUT_FILE\" -q:a 0 -map a \"$TMP_DIR/audio_in.${AUDIO_TYPE}\""
    fi

    echo "Processing audio as sound..."
    mv "$TMP_DIR/tmp.yuv" "$TMP_DIR/tmp_audio_in.${S_TYPE}"
    cmdSilent sox --bits "$BITS" -c1 -r44100 --encoding unsigned-integer -t "${S_TYPE}" "$TMP_DIR/tmp_audio_in.${S_TYPE}" \
                      --bits "$BITS" -c1 -r44100 --encoding unsigned-integer -t "${S_TYPE}" "$TMP_DIR/tmp_audio_out.${S_TYPE}" \
                      "${EFFECTS[@]}"
    if [[ $? -ne 0 ]]; then
        echo "Error: Sox failed during audio processing."
        cleanup 1
    fi

    if [[ $AUDIO = *[!\ ]* ]]; then
        echo "Processing audio track as sound..."
        cmdSilent sox "$TMP_DIR/audio_in.${AUDIO_TYPE}" "$TMP_DIR/audio_out.${AUDIO_TYPE}" "${EFFECTS[@]}"
    fi

    echo "Recreating image data from audio..."
    cmdSilent ffmpeg -y \
                     $(eval echo "$FFMPEG_OUT_OPTS") \
                     -f rawvideo -pix_fmt "$YUV_FMT" -s "$RES" -r "$FRAMERATE" \
                     -i "$TMP_DIR/tmp_audio_out.${S_TYPE}" \
                     $AUDIO \
                     $VIDEO \
                     -r "$FRAMERATE" \
                     "$OUTPUT_FILE"
    if [[ $? -ne 0 ]]; then
        echo "Error: ffmpeg failed during image data recreation."
        cleanup 1
    fi
fi

cleanup 0
