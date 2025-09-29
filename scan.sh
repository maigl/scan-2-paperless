#!/bin/bash

# Define the scanner command and parameters
RESOLUTION=150
SCAN_COMMAND="scanimage --format tiff --source ADF --mode COLOR --resolution $RESOLUTION"
DEVICE_STRING="escl:http://192.168.1.106:80"
FRONT_DIR="front_pages"
BACK_DIR="back_pages"
CLEANED_DIR="cleaned_pages"

# Check for required commands
command -v scanimage >/dev/null 2>&1 || { echo >&2 "scanimage is not installed. Aborting."; exit 1; }
command -v convert >/dev/null 2>&1 || { echo >&2 "ImageMagick (convert) is not installed. Aborting."; exit 1; }

# Create temporary directories
mkdir -p "$FRONT_DIR" "$BACK_DIR" "$CLEANED_DIR"

echo "--- Step 1: Scanning the front sides ---"
read -p "Please place all pages in the ADF, face up. Press [Enter] to start scanning..."

# Scan the front pages
cd "$FRONT_DIR"
$SCAN_COMMAND -d $DEVICE_STRING --batch=front_p%04d.tiff
cd ..
echo "Front pages scanned. Total pages: $(ls -1 "$FRONT_DIR" | wc -l)"

echo "--- Step 2: Scanning the back sides ---"
read -p "Please put the pages back in the ADF, face down. Press [Enter] to start scanning..."

# Scan the back pages (they will be in reverse order)
cd "$BACK_DIR"
$SCAN_COMMAND -d $DEVICE_STRING --batch=back_p%04d.tiff
cd ..
echo "Back pages scanned. Total pages: $(ls -1 "$BACK_DIR" | wc -l)"

# Check if the number of scanned pages matches
if [ $(ls -1 "$FRONT_DIR" | wc -l) -ne $(ls -1 "$BACK_DIR" | wc -l) ]; then
  echo "Error: The number of front and back pages do not match. Aborting."
  exit 1
fi

# Array to hold the sorted file list
sorted_files=()
num_pages=$(ls -1 "$FRONT_DIR" | wc -l)
echo "Number of pages: $num_pages"

LEVEL="15%x80%"

# Loop to interleave the front and back pages correctly
for (( i=1; i<=num_pages; i++ )); do
    front_file=$(printf "$FRONT_DIR/front_p%04d.tiff" $i)
    back_file=$(printf "$BACK_DIR/back_p%04d.tiff" $((num_pages-i+1)))
    
    # Check if files exist
    if [ -f "$front_file" ] && [ -f "$back_file" ]; then

	# Post-process the front page
        cleaned_front_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $((2*i-1))).tiff"
        convert "$front_file" -deskew 40% -fuzz 15% -trim +repage -level "$LEVEL" "$cleaned_front_file"

        # Post-process the back page
        cleaned_back_file="$CLEANED_DIR/cleaned_p$(printf "%04d" $((2*i))).tiff"
     	convert "$back_file" -deskew 40% -fuzz 15% -trim +repage -level "$LEVEL" "$cleaned_back_file"

        sorted_files+=("$cleaned_front_file")
        sorted_files+=("$cleaned_back_file")
    else
        echo "Warning: Missing file for page $i. Skipping..."
    fi
done

echo "--- Step 3: Merging and sorting pages ---"
PDF_NAME=$(date +%Y%m%d_%H%M%S).pdf

# Convert sorted TIFFs to a single PDF
echo "--- Step 4: Converting to PDF ---"
convert -compress JPEG -quality 85 "${sorted_files[@]}" "$PDF_NAME"

# Clean up temporary directories
#rm -r "$FRONT_DIR" "$BACK_DIR" "$CLEANED_DIR"

echo "✅ All done! Your document '$PDF_NAME' has been created."
