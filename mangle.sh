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
    echo "Error: \"$1\" could not be found, but is required"
    echo ""
    echo "This script requires ffmpeg, Sox, and ImageMagick to be installed"

    cleanup 1
}

function printEffects() {
    echo "Effects:"
    echo "bass 5"
    echo "echo 0.8 0.88 60 0.4"
    echo "flanger 0 2 0 71 0.5 25 lin"
    echo "hilbert -n 5001"
    echo "loudness 6"
    echo "norm 90"
    echo "overdrive 17"
    echo "phaser 0.8 0.74 3 0.7 0.5"
    echo "phaser 0.8 0.74 3 0.4 0.5"
    echo "pitch 2"
    echo "riaa"
    echo "sinc 20-4k"
    echo "vol 10"
}

function printHelp() {
    echo "$ ./mangle.sh in.jpg out.png [effect [effect]]"
    echo ""
    echo "This script lets you interpret image or video data as sound,"
    echo "and apply audio effects to it before converting it back to"
    echo "image representation"
    echo ""
    echo "Options:"
    echo "--bits=X          -- Set audio sample size in bits, 8/16/24"
    echo "--blend=X         -- Blend the distorted video with original video, 0.5"
    echo "--color-format=X  -- Color space/format, rgb24/yuv444p/yuyv422. Full list: \$ ffmpeg -pix_fmts"
    echo "--effects         -- Suggest some effects"
    echo "--help            -- Display this information"
    echo "--res=WxH         -- Set output resolution, 1920x1080"
    echo ""
    printEffects
    echo ""
    echo "Examples:"
    echo "./mangle in.jpg out.jpg vol 11"
    echo "./mangle in.mp4 out.mp4 echo 0.8 0.88 60 0.4"
    echo "./mangle in.mp4 out.mp4 pitch 5 --res=1280x720"
    echo "./mangle in.mp4 out.mp4 pitch 5 --blend=0.75 --color-format=yuv444p --bits=8"
    echo ""
    echo "A full list of effects can be found here: http://sox.sourceforge.net/sox.html#EFFECTS"

    cleanup 1
}

function helpNeeded() {
    if [[ -z ${1+x} ]]; then
        echo -e "Input file not provided!\n"
        printHelp
    elif [[ ! -f $1 ]]; then
        echo -e "Input file '$1' not found!\n"
        printHelp
    fi

    if [[ -z ${2+x} ]]; then
        echo -e "Output file not provided!\n"
        printHelp
    fi

    if [[ -z ${3+x} ]]; then
        echo -e "No effect specified\n"
        printHelp
    fi
}

function parseArgs() {
    # Default values
    BITS=8
    YUV_FMT=rgb24

    for i in "${@}"; do
        case $i in
            --effects)
                printEffects
                cleanup 0
            ;;
            --help)
                printHelp
            ;;
            *)
            ;;
        esac
    done

    for i in "${@:3}"; do
        case $i in
            --res=*)
                export RES=${i#*=}
                RES_COLON=$(echo "$RES" | tr x :)
                FFMPEG_IN_OPTS="$FFMPEG_IN_OPTS -vf scale=$RES_COLON"
            ;;
            --bits=*)
                BITS=${i#*=}
            ;;
            --blend=*)
                BLEND=${i#*=}
                FFMPEG_OUT_OPTS="$FFMPEG_OUT_OPTS -f rawvideo -pix_fmt \$YUV_FMT -s \${RES} -i \${TMP_DIR}/tmp_audio_out.\${S_TYPE}"
                FFMPEG_OUT_OPTS="$FFMPEG_OUT_OPTS -filter_complex \\\""
                FFMPEG_OUT_OPTS="$FFMPEG_OUT_OPTS [0:v]setpts=PTS-STARTPTS, scale=\${RES}[top]\;"
                FFMPEG_OUT_OPTS="$FFMPEG_OUT_OPTS [1:v]setpts=PTS-STARTPTS, scale=\${RES},"
                FFMPEG_OUT_OPTS="$FFMPEG_OUT_OPTS format=yuva444p,colorchannelmixer=aa=${BLEND}[bottom]\;"
                FFMPEG_OUT_OPTS="$FFMPEG_OUT_OPTS [top][bottom]overlay=shortest=1\\\""
            ;;
            --color-format=*)
                YUV_FMT=${i#*=}
            ;;
            --help)
                printHelp
            ;;
            --*)
                echo -e "Option $i not recognized\n"
                printHelp
            ;;
            *)
                # Unknown option, hand them back to SOX
                SOX_OPTS="$SOX_OPTS $i"
            ;;
        esac
    done

    helpNeeded "$@"

    export BITS
    export YUV_FMT

    export S_TYPE="u$BITS"

    export FFMPEG_IN_OPTS
    export FFMPEG_OUT_OPTS
    export UNUSED_ARGS
}

function cmd() {
    OUTPUT=$(eval "$@" 2>&1)
    if (( $? )); then
        echo -e "\n----- ERROR -----"
        echo -e "\n\$ ${*}\n\n"
        echo -e "$OUTPUT"
        echo -e "\n----- ERROR -----"
        cleanup 1
    fi
    echo "$OUTPUT"
}

function cmdSilent() {
    OUTPUT=$(eval "$@" 2>&1)
    if (( $? )); then
        echo -e "\n----- ERROR -----"
        echo -e "\n\$ ${*}\n\n"
        echo -e "$OUTPUT"
        echo -e "\n----- ERROR -----"
        cleanup 1
    fi
}

function getResolution() {
    eval $(cmd ffprobe -v error -of flat=s=_ -select_streams v:0 -show_entries stream=height,width "$1")
    RES="${streams_stream_0_width}${2}${streams_stream_0_height}"
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

# New function to get framerate
function getFramerate() {
    local input_file="$1"
    # Extract the raw framerate (e.g., "30000/1001")
    local framerate_raw=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$input_file")
    
    # Convert fractional framerate to decimal
    local framerate_decimal=$(awk -F'/' '{ 
        if ($2 != 0) 
            printf "%.6f", $1/$2; 
        else 
            print "0" 
    }' <<< "$framerate_raw")
    
    echo "$framerate_decimal"
}

# New function to check if input is GIF
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

# New function to extract GIF frames and delays
function extractGIFFrames() {
    local input_file="$1"
    local tmp_dir="$2"

    # Extract frames as individual PNG files
    magick convert "$input_file" "$tmp_dir/frame_%04d.png"

    # Extract frame delays (in centiseconds)
    magick identify -format "%T\n" "$input_file" > "$tmp_dir/delays.txt"

    # Extract loop count (0 means infinite)
    local loop_count
    loop_count=$(magick identify -format "%[iterations]" "$input_file")
    echo "$loop_count" > "$tmp_dir/loop_count.txt"
}

# New function to assemble GIF from frames and delays
function assembleGIF() {
    local frame_dir="$1"
    local output_file="$2"
    local tmp_dir="$3"

    # Read delays
    mapfile -t delays < "$tmp_dir/delays.txt"

    # Read loop count
    loop_count=$(cat "$tmp_dir/loop_count.txt")

    # Prepare a temporary frames list with delays
    local frame_files=("$frame_dir"/*.png)
    local frames_with_delays=()
    for i in "${!frame_files[@]}"; do
        frames_with_delays+=("-delay" "${delays[$i]}")
        frames_with_delays+=("${frame_files[$i]}")
    done

    # Assemble GIF with ImageMagick
    magick convert "${frames_with_delays[@]}" -loop "$loop_count" "$output_file"
}

# New function to optimize GIF using gifsicle (optional)
function optimizeGIF() {
    local input_file="$1"
    local output_file="$2"

    gifsicle -O3 "$input_file" -o "$output_file"
}

# New function to check if input is GIF
# (Already defined above)

function checkDependencies() {
    for CMD in "$@"; do
        if ! type "$CMD" > /dev/null; then
            printDependencies "$CMD"
        fi
    done
}

checkDependencies ffprobe ffmpeg sox tr magick gifsicle

parseArgs "$@"

# Create a unique temporary directory within the script's directory
TMP_DIR=$(mktemp -d "${SCRIPT_DIR}/tmp_audio_shop_XXXXXX")

INPUT_FILE="$1"
OUTPUT_FILE="$2"

if isGIF "$INPUT_FILE"; then
    IS_GIF=1
else
    IS_GIF=0
fi

export IS_GIF

AUDIO_TYPE="mp3"
RES=${RES:-"$(getResolution "$INPUT_FILE" x)"}
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

if [[ "$IS_GIF" -eq 1 ]]; then
    FRAME_DIR="$TMP_DIR/frames"
    mkdir -p "$FRAME_DIR"
    echo "Extracting GIF frames and delays.."
    extractGIFFrames "$INPUT_FILE" "$FRAME_DIR"

    echo "Processing frames as images.."
    for frame in "$FRAME_DIR"/*.png; do
        # Example image processing; replace with actual effects
        magick convert "$frame" -brightness-contrast 10x0 "$frame"
    done

    echo "Reassembling GIF.."
    assembleGIF "$FRAME_DIR" "$OUTPUT_FILE" "$TMP_DIR"

    echo "Optimizing GIF.."
    optimizeGIF "$OUTPUT_FILE" "$OUTPUT_FILE"

else
    # Proceed with existing video processing
    echo "Extracting raw image data.."
    cmdSilent "ffmpeg -y -i \"$INPUT_FILE\" -pix_fmt $YUV_FMT $FFMPEG_IN_OPTS  $TMP_DIR/tmp.yuv"

    [[ $AUDIO = *[!\ ]* ]] && echo "Extracting audio track.."
    [[ $AUDIO = *[!\ ]* ]] && cmdSilent "ffmpeg -y -i \"$INPUT_FILE\" -q:a 0 -map a $TMP_DIR/audio_in.${AUDIO_TYPE}"

    echo "Processing as sound.."
    mv "$TMP_DIR"/tmp.yuv "$TMP_DIR"/tmp_audio_in."$S_TYPE"
    cmdSilent sox --bits "$BITS" -c1 -r44100 --encoding unsigned-integer -t "$S_TYPE" "$TMP_DIR"/tmp_audio_in."$S_TYPE"  \
                  --bits "$BITS" -c1 -r44100 --encoding unsigned-integer -t "$S_TYPE" "$TMP_DIR"/tmp_audio_out."$S_TYPE" \
                  "$SOX_OPTS"

    [[ $AUDIO = *[!\ ]* ]] && echo "Processing audio track as sound.."
    [[ $AUDIO = *[!\ ]* ]] && cmdSilent sox "$TMP_DIR"/audio_in.${AUDIO_TYPE}  \
                                            "$TMP_DIR"/audio_out.${AUDIO_TYPE} \
                                            "$SOX_OPTS"

    echo "Recreating image data from audio.."
    cmdSilent ffmpeg -y \
                     "$(eval echo $FFMPEG_OUT_OPTS)" \
                     -f rawvideo -pix_fmt $YUV_FMT -s $RES -r "$FRAMERATE" \
                     -i "$TMP_DIR/tmp_audio_out.$S_TYPE" \
                     $AUDIO \
                     $VIDEO \
                     -r "$FRAMERATE" \
                     "$OUTPUT_FILE"
fi

cleanup 0
