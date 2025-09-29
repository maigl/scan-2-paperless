#!/bin/bash


# Default values
RESOLUTION=300
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

scan_with_retry() {
  local dir="$1"
  local batch_pattern="$2"
  local attempt=1
  local max_attempts=5
  local sleep_time=3
  local success=0
  while [ $attempt -le $max_attempts ]; do
    echo "Scan attempt $attempt in $dir..."
    output=$(cd "$dir" && $SCAN_COMMAND -d $DEVICE_STRING --batch=$batch_pattern 2>&1)
    # If any pages were scanned, abort further retries
    local scanned_count=$(ls -1 "$dir" | wc -l)
    if [ "$scanned_count" -gt 0 ]; then
      echo "$output"
      success=1
      break
    fi
    if echo "$output" | grep -q "scanimage: sane_start: Document feeder out of documents"; then
      echo "No documents detected. Waiting $sleep_time seconds before retrying..."
      sleep $sleep_time
      attempt=$((attempt+1))
    else
      echo "$output"
      success=1
      break
    fi
  done
  if [ $success -eq 0 ]; then
    echo "Failed to scan after $max_attempts attempts."
  fi
}

echo "Scanning the front sides ---"
scan_with_retry "$FRONT_DIR" "front_p%04d.tiff"
front_count=$(ls -1 "$FRONT_DIR" | wc -l)
echo "Front pages scanned. Total pages: $front_count"
if [ "$front_count" -eq 0 ]; then
  echo "No documents scanned from the front side. Aborting."
  exit 1
fi

echo "Scanning the back sides ---"
scan_with_retry "$BACK_DIR" "back_p%04d.tiff"
echo "Back pages scanned. Total pages: $(ls -1 "$BACK_DIR" | wc -l)"

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
  # Only front pages exist, process them
  for (( i=1; i<=num_front; i++ )); do
    front_file=$(printf "$FRONT_DIR/front_p%04d.tiff" $i)
    if [ -f "$front_file" ]; then
      cleaned_front_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $i).tiff"
      convert "$front_file" -deskew "$DESKEW" -fuzz "$FUZZ" -trim +repage -level "$LEVEL" "$cleaned_front_file"
      sorted_files+=("$cleaned_front_file")
    else
      echo "Warning: Missing front file for page $i. Skipping..."
    fi
  done
elif [ "$num_back" -eq "$num_front" ]; then
  # Interleave front and back pages
  for (( i=1; i<=num_front; i++ )); do
    front_file=$(printf "$FRONT_DIR/front_p%04d.tiff" $i)
    back_file=$(printf "$BACK_DIR/back_p%04d.tiff" $((num_front-i+1)))
    if [ -f "$front_file" ] && [ -f "$back_file" ]; then
      cleaned_front_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $((2*i-1))).tiff"
      convert "$front_file" -deskew "$DESKEW" -fuzz "$FUZZ" -trim +repage -level "$LEVEL" "$cleaned_front_file"
      cleaned_back_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $((2*i))).tiff"
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
