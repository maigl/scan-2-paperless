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

echo "Scanning the front sides ---"
read -p "Please place all pages in the ADF, face up. Press [Enter] to start scanning..."

# Scan the front pages
(cd "$FRONT_DIR" && $SCAN_COMMAND -d $DEVICE_STRING --batch=front_p%04d.tiff)
echo "Front pages scanned. Total pages: $(ls -1 "$FRONT_DIR" | wc -l)"

echo "Scanning the back sides ---"
read -p "Please put the pages back in the ADF, face down. Press [Enter] to start scanning..."

# Scan the back pages (they will be in reverse order)
(cd "$BACK_DIR" && $SCAN_COMMAND -d $DEVICE_STRING --batch=back_p%04d.tiff)
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

convert_in_background() {
  local src="$1"
  local dest="$2"
  if [ -f "$src" ]; then
    convert "$src" -deskew "$DESKEW" -fuzz "$FUZZ" -trim +repage -level "$LEVEL" "$dest" &
  fi
}

scan_and_convert() {
  local scan_dir="$1"
  local batch_pattern="$2"
  local cleaned_dir="$3"
  local prefix="$4"
  local scan_count_var="$5"

  # Start scan in background
  (cd "$scan_dir" && $SCAN_COMMAND -d $DEVICE_STRING --batch=$batch_pattern) &
  local scan_pid=$!

  local last_converted=0
  local bg_pids=()

  while kill -0 $scan_pid 2>/dev/null; do
    # Find new TIFFs
    for tiff in $(ls "$scan_dir"/${prefix}_p*.tiff 2>/dev/null); do
      idx=$(echo "$tiff" | grep -oP '(?<=_p)\d+' | sed 's/^0*//')
      cleaned_file="$cleaned_dir/cleaned_p$(printf "%04d" $idx).tiff"
      if [ ! -f "$cleaned_file" ]; then
        convert_in_background "$tiff" "$cleaned_file"
        bg_pids+=("$!")
      fi
    done
    sleep 1
  done

  # Final conversion for any remaining TIFFs
  for tiff in $(ls "$scan_dir"/${prefix}_p*.tiff 2>/dev/null); do
    idx=$(echo "$tiff" | grep -oP '(?<=_p)\d+' | sed 's/^0*//')
    cleaned_file="$cleaned_dir/cleaned_p$(printf "%04d" $idx).tiff"
    if [ ! -f "$cleaned_file" ]; then
      convert_in_background "$tiff" "$cleaned_file"
      bg_pids+=("$!")
    fi
  done

  # Wait for all background conversions
  for pid in "${bg_pids[@]}"; do
    wait $pid
  done

  # Set scan count variable
  eval $scan_count_var=$(ls "$scan_dir"/${prefix}_p*.tiff 2>/dev/null | wc -l)
}

# Scanning and converting front pages
scan_and_convert "$FRONT_DIR" "front_p%04d.tiff" "$CLEANED_DIR" "front" front_count
if [ "$front_count" -eq 0 ]; then
  echo "No documents scanned from the front side. Aborting."
  exit 1
fi

echo "Front pages scanned. Total pages: $front_count"

# Scanning and converting back pages
scan_and_convert "$BACK_DIR" "back_p%04d.tiff" "$CLEANED_DIR" "back" back_count
echo "Back pages scanned. Total pages: $back_count"

# Determine number of front and back pages
num_front=$(ls -1 "$FRONT_DIR" | wc -l)
num_back=$(ls -1 "$BACK_DIR" | wc -l)
echo "Number of front pages: $num_front"
echo "Number of back pages: $num_back"

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
