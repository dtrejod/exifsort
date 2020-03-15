#!/bin/bash
#
#
# The following are the only settings you should need to change:
#
# TS_AS_FILENAME: This can help eliminate duplicate images during sorting.
# TRUE: File will be renamed to the Unix timestamp and its extension.
# FALSE (any non-TRUE value): Filename is unchanged.
TS_AS_FILENAME=TRUE
#
# USE_LMDATE: If this is TRUE, images without EXIF data will have their Last Modified file
# timestamp used as a fallback. If FALSE, images without EXIF data are put in noexif/ for
# manual sorting.
# Valid options are "TRUE" or anything else (assumes FALSE). FIXME: Restrict to TRUE/FALSE
#
USE_LMDATE=FALSE
#
# USE_FILE_EXT: The following option is here as a compatibility option as well as a bugfix.
# If this is set to TRUE, files are identified using FILE's magic, and the extension
# is set accordingly. If FALSE (or any other value), file extension is left as-is.
# CAUTION: If set to TRUE, extensions may be changed to values you do not expect.
# See the manual page for file(1) to understand how this works.
# NOTE: This option is only honored if TS_AS_FILENAME is TRUE.
#
USE_FILE_EXT=TRUE
#
# JPEG_TO_JPG: The following option is here for personal preference. If TRUE, this will
# cause .jpg to be used instead of .jpeg as the file extension. If FALSE (or any other
# value) .jpeg is used instead. This is only used if USE_FILE_EXT is TRUE and used.
#
JPEG_TO_JPG=TRUE
#
# The following is an array of filetypes that we intend to locate using find.
# Script will optionally use the last-modified time for sorting (see above).
# Extensions are matched case-insensitive. *.jpg is treated the same as *.JPG, etc.
# Can handle any file type; not just EXIF-enabled file types. See USE_LMDATE above.
#
FILETYPES=("*.jpg" "*.jpeg" "*.png" "*.tif" "*.tiff" "*.gif" "*.xcf" "*.mp4" "*.avi" "*.mov")
#
# The following is an array of directories to ignore when finding folders.
#
DIR_BLACKLIST=('*lost*' '*noexif*' '*duplicates*' '*slideshows*' '*raw*')
#
# The following will make no changes unless DRY_RUN is set to false.
#
DRY_RUN="true"
#
# Optional: Prefix of new top-level directory to kjmove sorted photos to.
# if you use MOVETO, it MUST have a trailing slash! Can be a relative pathspec, but an
# absolute pathspec is recommended.
# FIXME: Gracefully handle unavailable destinations, non-trailing slash, etc.
#
MOVETO=""
#
###############################################################################
# End of settings. If you feel the need to modify anything below here, please share
# your edits at the URL above so that improvements can be made to the script. Thanks!
#
#
# Assume find, grep, stat, awk, sed, tr, etc.. are already here, valid, and working.
# This may be an issue for environments which use gawk instead of awk, etc.
# Please report your environment and adjustments at the URL above.
#
###############################################################################
# Nested execution (action) call
# This is invoked when the programs calls itself with
# $1 = "doAction"
# $2 = <file to handle>
# This is NOT expected to be run by the user in this matter, but can be for single image
# sorting. Minor output issue when run in this manner. Related to find -print0 below.
#
# Are we supposed to run an action? If not, skip this entire section.
if [[ "$1" == "doAction" && "$2" != "" ]]; then
    exact_duplicate=1
    # Check for EXIF and process it
    echo -n ": Checking EXIF... "

    # DATETIME FORMAT: 2017:02:20 21:43:11
    DATETIME=$(exiftool -S -s "-datetimeoriginal" -d "%Y:%m:%d %H:%M:%S" "$2")

    # If identify fails use identify instead (only if photo)
    if [[ "$DATETIME" == "" ]] && $(file "$2" | grep -qE 'image|bitmap'); then
        identify -verbose "$2" 2>/dev/null| grep "exif:DateTimeOriginal" | awk -F' ' '{print $2" "$3}'
    fi

    # If identify fails b/c video file then attempt to use mediainfo
    if [[ "$DATETIME" == "" ]] && $(file "$2" | grep -qvE 'image|bitmap'); then
        MEDIAINFO=$(mediainfo "$2"|grep -m 1 -E 'Tagged date|Mastered date')

        i=0
        while [[ "$DATETIME" == ""  ]] ; do
            case $i in
            0)
                # For "Tagged date" match
                DATETIME=$(echo "${MEDIAINFO}" | sed -nr 's/.*([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1:\2:\3 \4:\5:\6/p')
                i=$((i+1))
                ;;
            1)
                # For "Mastered date" match
                # Master Date v01 -- FRI JAN 11 22:14:20 2013
                PARSETIME=$(echo "${MEDIAINFO}" | sed -nr 's/.*([A-Z]{3}) ([A-Z]{3}) ([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4}).*/\3-\2-\7 \4:\5:\6/p')

                # Master Date v02 -- 2004-04-06 09:56:51 (default fallback)
                if [[ "$PARSETIME" == "" ]]; then
                    PARSETIME=$(echo "$MEDIAINFO" | sed 's/Mastered date.*: //g' )
                fi
                if [[ "$PARSETIME" != "" ]]; then
                    DATETIME=$(date -d "$PARSETIME" '+%Y:%m:%d %H:%M:%S')
                fi
                i=$((i+1))
                ;;
            *)
                break
                ;;
            esac
        done
        unset i
    fi

    if [[ "$DATETIME" == "" ]]; then
        echo "not found."

        if [[ $USE_LMDATE == "TRUE" ]]; then
            # I am deliberately not using %Y here because of the desire to display the date/time
            # to the user, though I could avoid a lot of post-processing by using it.
            DATETIME=`stat --printf='%y' "$2" | awk -F. '{print $1}' | sed y/-/:/`
            echo " Using LMDATE: $DATETIME"
        else
            echo " Moving to ./noexif/"
            echo DEBUG: mkdir -p "${MOVETO}noexif" && echo mv -n "$2" "${MOVETO}noexif/"
            if [[ "$DRY_RUN" == "false" ]]; then
                mkdir -p "${MOVETO}noexif" && mv -n "$2" "${MOVETO}noexif/"
            fi
            exit
        fi
    else
        echo "found: $DATETIME"
    fi

    # The previous iteration of this script had a major bug which involved handling the
    # renaming of the file when using TS_AS_FILENAME. The following sections have been
    # rewritten to handle the action correctly as well as fix previously mangled filenames.
    # FIXME: Collisions are not fully handled.
    #
    EDATE=`echo $DATETIME | awk -F' ' '{print $1}'`

    # Evaluate the correct file extension (excluding videos)
    if [ "$USE_FILE_EXT" == "TRUE" ] && $(file "$2" | grep -qE 'image|bitmap'); then
        # Get the FILE type and lowercase it for use as the extension
        EXT=`file -b "$2" | awk -F' ' '{print $1}' | tr '[:upper:]' '[:lower:]'`

        if [[ "${EXT}" == "jpeg" && "${JPEG_TO_JPG}" == "TRUE" ]]; then EXT="jpg"; fi;
    else
        # Lowercase and use the current extension as-is
        EXT=`echo "$2" | awk -F. '{print $NF}' | tr '[:upper:]' '[:lower:]'`
    fi

    # DIRectory NAME for the file move
    # sed issue for y command fix provided by thomas
    DIRNAME=`echo $EDATE | sed y-:-/-`

    # Evaluate the file name
    if [ "$TS_AS_FILENAME" == "TRUE" ]; then
        # Get date and times from EXIF stamp
        ETIME=`echo $DATETIME | awk -F' ' '{print $2}'`

        # Unix Formatted DATE and TIME - For feeding to date()
        UFDATE=`echo $EDATE | sed y/:/-/`

        # Unix DateSTAMP
        UDSTAMP=$(date -d "$UFDATE $ETIME" +%s)
        MVCMD="/$UDSTAMP.$EXT"

        # Handle collisions
        while [[ -e "${MOVETO}${DIRNAME}${MVCMD}" ]] ; do
            # Check if photo is duplicate
            if [[ $DIRNAME != "duplicates" ]] && ( $(nice -n 19 cmp "$2" "${MOVETO}${DIRNAME}${MVCMD}" >/dev/null) || ( $(file "$2" | grep -qE 'image|bitmap') && [[ "$(nice -n 19 convert "$2" "${MOVETO}${DIRNAME}${MVCMD}" -trim +repage -resize "256x256^!" -metric RMSE -format %[distortion] -compare info:)" == "0" ]] )) ; then
                echo "INFO: Duplicate detected"
                DIRNAME="duplicates"
                unset i
                continue
            fi
            let ${i:=-1}
            i=$((i+1))
            MVCMD="/$UDSTAMP-$i.$EXT"
        done
        unset i

        echo "INFO: Will rename to $(basename $MVCMD)"
    fi

    # Fix permissions
    chmod 644 "$2"

    echo DEBUG: mkdir -p "${MOVETO}${DIRNAME}" && echo mv -n "$2" "${MOVETO}${DIRNAME}${MVCMD}"
    if [[ "$DRY_RUN" == "false" ]]; then
        mkdir -p "${MOVETO}${DIRNAME}" && mv -n "$2" "${MOVETO}${DIRNAME}${MVCMD}"
    fi
    echo -e "INFO: done.\n"
    exit
fi;

function join_by { local d=$1; shift; echo -n "$1"; shift; printf "%s" "${@/#/$d}"; }
#
###############################################################################
# Scanning (find) loop
# This is the normal loop that is run when the program is executed by the user.
# This runs find for the recursive searching, then find invokes this program with the two
# parameters required to trigger the above loop to do the heavy lifting of the sorting.
# Could probably be optimized into a function instead, but I don't think there's an
# advantage performance-wise. Suggestions are welcome at the URL at the top.
for x in "${FILETYPES[@]}"; do
    # Check for the presence of helper utilities.
    # Assuming its valid and working if found.
    if [ "$(which identify)" == "" ]; then
        echo "The 'identify' command is missing or not available. Ensure imagemagick is installed."
        exit 1
    fi
    if [ "$(which mediainfo)" == "" ]; then
        echo "The 'mediainfo' command is missing or not available. Ensure mediainfo is installed."
        exit 1
    fi

    echo "Scanning for $x..."

    # Make blacklist from arguments
    if [[ ${#DIR_BLACKLIST[@]} -ne 0 ]]; then
        temp=( "${DIR_BLACKLIST[@]/#/-iname }" )

        # Since we added prefix above with spaces, we need a different IFS
        IFS=':'
        dir_blacklist="$(join_by ' -prune -o ' ${temp[@]})"
        IFS=" "
    fi

    # Run
    find . \( -regextype posix-awk -regex "./[0-9]{4}" $dir_blacklist \) -o -type f -iname "$x" -print0 -exec sh -c "$0 doAction \"{}\"" \;
    echo "... end of $x"
done

# clean up empty directories. Find can do this easily.
# Remove Thumbs.db first because of thumbnail caching
echo "INFO: Removing THM files ... "
find . -iname '.thm' -delete
echo "INFO: Removing Thumbs.db files ... "
find . -name Thumbs.db -delete
echo "INFO: done."
echo "INFO: Cleaning up empty directories ... "
find . -empty -delete
echo "INFO: done."
echo "INFO: Recreating dump directory ... "
mkdir dump
touch dump/.exclude_from_backup
echo "INFO: done."
