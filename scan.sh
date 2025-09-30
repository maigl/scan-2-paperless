#!/bin/bash


# Default values
RESOLUTION=150
SCAN_COMMAND="scanimage --format tiff --source ADF --mode COLOR --resolution $RESOLUTION"
DEVICE_STRING="escl:http://192.168.1.106:80"
OUTPUT_DIR="/output"

# Parse options
OPTS=$(getopt -o o:r: --long output:,resolution: -n 'scan.sh' -- "$@")
if [ $? != 0 ]; then echo "Failed to parse options." >&2; exit 1; fi
eval set -- "$OPTS"
while true; do
    case "$1" in
        -o|--output)
            OUTPUT_DIR="$2"; shift 2;;
        -r|--resolution)
            RESOLUTION="$2"; shift 2;;
        --)
            shift; break;;
        *)
            echo "Internal error!"; exit 1;;
    esac

done

echo "Output directory: $OUTPUT_DIR"
echo "Scan resolution: $RESOLUTION DPI"
echo "Device string: $DEVICE_STRING" 

SCAN_COMMAND="scanimage --format tiff --source ADF --mode COLOR --resolution $RESOLUTION"

# Create temporary directories
FRONT_DIR=$(mktemp -d)
BACK_DIR=$(mktemp -d)
CLEANED_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    rm -rf "$FRONT_DIR" "$BACK_DIR" "$CLEANED_DIR"
}
trap cleanup EXIT

# Check for required commands
command -v scanimage >/dev/null 2>&1 || { echo >&2 "scanimage is not installed. Aborting."; exit 1; }
command -v convert >/dev/null 2>&1 || { echo >&2 "ImageMagick (convert) is not installed. Aborting."; exit 1; }

echo "Scanning the front sides ---"
read -p "Please place all pages in the ADF, face up. Press [Enter] to start scanning..."

# Scan the front pages
(cd "$FRONT_DIR" && $SCAN_COMMAND -d $DEVICE_STRING --batch=front_p%04d.tiff)
echo "Front pages scanned. Total pages: $(ls -1 "$FRONT_DIR" | wc -l)"


# Start converting front pages in the background
DESKEW="40%"
FUZZ="15%"
LEVEL="25%x87%"
convert_front() {
  echo "Starting front pages conversion..."
  for (( i=1; i<=$(ls -1 "$FRONT_DIR" | wc -l); i++ )); do
    front_file=$(printf "$FRONT_DIR/front_p%04d.tiff" $i)
    if [ -f "$front_file" ]; then
      cleaned_front_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $i).tiff"
      convert "$front_file" -deskew "$DESKEW" -fuzz "$FUZZ" -trim +repage -level "$LEVEL" "$cleaned_front_file"
    else
      echo "Warning: Missing front file for page $i. Skipping..."
    fi
  done
  echo "Front pages conversion completed."
}
convert_front &
front_convert_pid=$!

echo "Scanning the back sides ---"
read -p "Please put the pages back in the ADF, face down. Press [Enter] to start scanning..."

# Scan the back pages (they will be in reverse order)
(cd "$BACK_DIR" && $SCAN_COMMAND -d $DEVICE_STRING --batch=back_p%04d.tiff)
echo "Back pages scanned. Total pages: $(ls -1 "$BACK_DIR" | wc -l)"

# Wait for front conversion to finish
wait $front_convert_pid

# Determine number of front and back pages
num_front=$(ls -1 "$FRONT_DIR" | wc -l)
num_back=$(ls -1 "$BACK_DIR" | wc -l)
echo "Number of front pages: $num_front"
echo "Number of back pages: $num_back"

DESKEW="40%"
FUZZ="15%"
LEVEL="25%x87%"
sorted_files=()

if [ "$num_back" -eq 0 ]; then
  # Only front pages exist, use already cleaned files
  for (( i=1; i<=num_front; i++ )); do
    cleaned_front_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $i).tiff"
    if [ -f "$cleaned_front_file" ]; then
      sorted_files+=("$cleaned_front_file")
    else
      echo "Warning: Missing cleaned front file for page $i. Skipping..."
    fi
  done
elif [ "$num_back" -eq "$num_front" ]; then
  # Interleave already cleaned front and newly cleaned back pages
  for (( i=1; i<=num_front; i++ )); do
    cleaned_front_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $i).tiff"
    back_file=$(printf "$BACK_DIR/back_p%04d.tiff" $((num_front-i+1)))
    cleaned_back_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $((num_front+i))).tiff"
    if [ -f "$cleaned_front_file" ] && [ -f "$back_file" ]; then
      convert "$back_file" -deskew "$DESKEW" -fuzz "$FUZZ" -trim +repage -level "$LEVEL" "$cleaned_back_file"
      sorted_files+=("$cleaned_front_file")
      sorted_files+=("$cleaned_back_file")
    else
      echo "Warning: Missing file for page $i. Skipping..."
    fi
  done
else
  echo "Error: The number of back pages does not match the number of front pages. Aborting."
  exit 1
fi

echo "--- Step 3: Merging and sorting pages ---"
PDF_NAME=$(date +%Y%m%d_%H%M%S).pdf
PDF_PATH="$OUTPUT_DIR/$PDF_NAME"

# Convert sorted TIFFs to a single PDF
echo "--- Step 4: Converting to PDF ---"
convert -compress JPEG -quality 85 "${sorted_files[@]}" "$PDF_PATH"

echo "✅ All done! Your document '$PDF_PATH' has been created."
