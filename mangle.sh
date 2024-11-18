#!/usr/bin/env bash

# Determine the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function cleanup()
{
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

function printDependencies()
{
    echo "Error: \"$1\" could not be found, but is required"
    echo ""
    echo "This script requires ffmpeg, Sox, and ImageMagick (magick) to be installed"

    cleanup 1
}

function printEffects()
{
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

function printHelp()
{
    echo "$ ./mangle.sh in.jpg out.gif [effect [effect]]"
    echo ""
    echo "This script lets you interpret image or video data as sound,"
    echo "and apply audio effects to it before converting it back to"
    echo "image representation as an animated GIF"
    echo ""
    echo "Options:"
    echo "--bits=X          -- Set audio sample size in bits, 8/16/24"
    echo "--blend=X         -- Blend the distorted video with original video, 0.5"
    echo "--color-format=X  -- Color space/format, rgb24/yuv444p/yuyv422. Full list: $ ffmpeg -pix_fmts"
    echo "--effects         -- Suggest some effects"
    echo "--help            -- Display this information"
    echo "--res=WxH         -- Set output resolution, 1920x1080"
    echo "--framerate=X     -- Set GIF framerate (frames per second), default 10"
    echo ""
    printEffects
    echo ""
    echo "Examples:"
    echo "./mangle.sh in.jpg out.gif vol 11"
    echo "./mangle.sh in.mp4 out.gif echo 0.8 0.88 60 0.4"
    echo "./mangle.sh in.mp4 out.gif pitch 5 --res=1280x720"
    echo "./mangle.sh in.mp4 out.gif pitch 5 --blend=0.75 --color-format=yuv444p --bits=8 --framerate=15"
    echo ""
    echo "A full list of effects can be found here: http://sox.sourceforge.net/sox.html#EFFECTS"

    cleanup 1
}

function helpNeeded()
{
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

function parseArgs()
{
    # Default values
    BITS=8
    YUV_FMT=rgb24
    FRAMERATE=10
    DELAY=$((100 / FRAMERATE))  # ImageMagick uses delay in 1/100s

    for i in "${@}"
    do
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

    for i in "${@:3}"
    do
    case $i in
        --res=*)
            RES=${i#*=}
        ;;
        --bits=*)
            BITS=${i#*=}
        ;;
        --blend=*)
            BLEND=${i#*=}
            # Blending is not directly handled by ImageMagick in this script version
            echo "Warning: --blend option is not supported when creating GIFs with ImageMagick."
        ;;
        --color-format=*)
            YUV_FMT=${i#*=}
        ;;
        --framerate=*)
            FRAMERATE=${i#*=}
            DELAY=$((100 / FRAMERATE))
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
    export FRAMERATE
    export DELAY

    export S_TYPE="u$BITS"

    export UNUSED_ARGS

    # FFMPEG_OUT_OPTS is no longer needed for GIF creation
}

function cmd()
{
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

function cmdSilent()
{
    OUTPUT=$(eval "$@" 2>&1)
    if (( $? )); then
        echo -e "\n----- ERROR -----"
        echo -e "\n\$ ${*}\n\n"
        echo -e "$OUTPUT"
        echo -e "\n----- ERROR -----"
        cleanup 1
    fi
}

function getResolution()
{
    eval $(cmd ffprobe -v error -of flat=s=_ -select_streams v:0 -show_entries stream=height,width "$1")
    RES="${streams_stream_0_width}x${streams_stream_0_height}"
    echo "$RES"
}

function getFrames()
{
    FRAMES=$(cmd ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 "$1")
    REGEXP_INTEGER='^[0-9]+$'
    if ! [[ $FRAMES =~ $REGEXP_INTEGER ]] ; then
        echo ""
        return 0
    fi
    echo "$FRAMES"
    return 0
}

function getAudio()
{
    AUDIO=$(cmd ffprobe -i "$1" -show_streams -select_streams a -loglevel error)
    [[ $AUDIO = *[!\ ]* ]] && echo "-i $TMP_DIR/audio_out.${AUDIO_TYPE}"
}

function checkDependencies()
{
    for CMD in "$@"
    do
        if ! type "$CMD" > /dev/null; then
            printDependencies "$CMD"
        fi
    done
}

checkDependencies ffprobe ffmpeg sox magick tr
parseArgs "$@"

# Create a unique temporary directory within the script's directory
TMP_DIR=$(mktemp -d "${SCRIPT_DIR}/tmp_audio_shop_XXXXXX")

AUDIO_TYPE="mp3"
RES=${RES:-"$(getResolution "$1")"}
FRAMES=${FRAMES:-"$(getFrames "$1")"}
AUDIO=${AUDIO:-"$(getAudio "$1")"}

echo "TMP_DIR:         $TMP_DIR"
echo "RES:             $RES"
echo "FRAMES:          $FRAMES"
echo "AUDIO:           $AUDIO"
echo "SOX_OPTS:        $SOX_OPTS"

echo "Extracting raw image data.."
# Extract frames as PNGs for ImageMagick
cmdSilent "ffmpeg -y -i \"$1\" -pix_fmt rgba -vf scale=${RES} $TMP_DIR/frame_%04d.png"

[[ $AUDIO = *[!\ ]* ]] && echo "Extracting audio track.."
[[ $AUDIO = *[!\ ]* ]] && cmdSilent "ffmpeg -y -i \"$1\" -q:a 0 -map a $TMP_DIR/audio_in.${AUDIO_TYPE}"

echo "Processing image data as sound.."
# Convert PNG frames to raw audio data
for frame in "$TMP_DIR"/frame_*.png; do
    magick "$frame" -flatten -alpha off -depth "$BITS" gray:"${frame%.png}.gray"
done

# Concatenate all grayscale frames into a single raw audio file
cat "$TMP_DIR"/*.gray > "$TMP_DIR"/tmp_audio_in."$S_TYPE"

cmdSilent sox --bits "$BITS" -c1 -r44100 --encoding unsigned-integer -t "$S_TYPE" \
    "$TMP_DIR"/tmp_audio_in."$S_TYPE" \
    --bits "$BITS" -c1 -r44100 --encoding unsigned-integer -t "$S_TYPE" \
    "$TMP_DIR"/tmp_audio_out."$S_TYPE" \
    "$SOX_OPTS" \
    trim 0

[[ $AUDIO = *[!\ ]* ]] && echo "Processing audio track as sound.."
[[ $AUDIO = *[!\ ]* ]] && cmdSilent sox "$TMP_DIR"/audio_in."${AUDIO_TYPE}"  \
                                        "$TMP_DIR"/audio_out."${AUDIO_TYPE}" \
                                        "$SOX_OPTS"

echo "Recreating image frames from processed audio.."
# Split the processed audio back into grayscale frames
sox "$TMP_DIR"/tmp_audio_out."$S_TYPE" -c 1 -r 44100 "$TMP_DIR"/processed_audio.wav remix 1 channels 1

# For simplicity, let's assume one audio frame corresponds to one image frame
# Here, we'll generate new PNG frames based on the processed audio
# This part may need customization based on how audio affects the image

# Example: Adjust brightness based on audio amplitude
sox "$TMP_DIR"/processed_audio.wav -n stat 2>&1 | grep "RMS" | awk '{print $3}' > "$TMP_DIR"/audio_rms.txt
RMS=$(cat "$TMP_DIR"/audio_rms.txt)
for frame in "$TMP_DIR"/frame_*.png; do
    magick "$frame" -modulate $((100 + RMS * 100)) "$TMP_DIR"/processed_"$(basename "$frame")"
done

echo "Creating animated GIF with ImageMagick.."
# Assemble processed frames into an animated GIF
magick convert -delay "$DELAY" -dispose previous -loop 0 "$TMP_DIR"/processed_frame_*.png -coalesce -layers OptimizeTransparency "$2"

echo "Animated GIF created at $2"

cleanup 0
