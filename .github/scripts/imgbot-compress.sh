#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$ROOT_DIR"

BEFORE_SHA="${BEFORE_SHA:-}"
AFTER_SHA="${AFTER_SHA:-HEAD}"
JPEG_QUALITY="${JPEG_QUALITY:-82}"
WEBP_QUALITY="${WEBP_QUALITY:-80}"

is_image_file() {
  local file="$1"
  [[ "$file" =~ \.(jpg|jpeg|png|webp)$ ]]
}

list_candidate_files() {
  local before="$1"
  local after="$2"

  if [[ -n "$before" ]] && [[ ! "$before" =~ ^0+$ ]] && git cat-file -e "$before^{commit}" 2>/dev/null; then
    git diff --name-only "$before" "$after"
  else
    git ls-files
  fi
}

human_bytes() {
  local bytes="$1"
  if (( bytes < 1024 )); then
    echo "${bytes} B"
  elif (( bytes < 1048576 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.2f KiB", b / 1024 }'
  else
    awk -v b="$bytes" 'BEGIN { printf "%.2f MiB", b / 1048576 }'
  fi
}

compress_file() {
  local file="$1"
  local ext="${file##*.}"
  ext="${ext,,}"
  local tmp_file
  tmp_file="$(mktemp --suffix=".${ext}")"
  trap 'rm -f "$tmp_file"' RETURN

  case "$ext" in
    jpg|jpeg)
      magick "$file" -strip -interlace Plane -quality "$JPEG_QUALITY" "$tmp_file"
      ;;
    png)
      magick "$file" -strip -define png:compression-level=9 -define png:compression-filter=5 "$tmp_file"
      ;;
    webp)
      magick "$file" -strip -quality "$WEBP_QUALITY" "$tmp_file"
      ;;
    *)
      return 1
      ;;
  esac

  local original_size optimized_size
  original_size="$(stat -c%s "$file")"
  optimized_size="$(stat -c%s "$tmp_file")"

  if (( optimized_size >= original_size )); then
    return 2
  fi

  mv "$tmp_file" "$file"
  trap - RETURN

  local bytes_saved percent_saved
  bytes_saved=$((original_size - optimized_size))
  percent_saved="$(awk -v o="$original_size" -v n="$optimized_size" 'BEGIN { printf "%.2f", ((o - n) / o) * 100 }')"

  echo "| \`$file\` | $(human_bytes "$original_size") | $(human_bytes "$optimized_size") | $(human_bytes "$bytes_saved") | ${percent_saved}% |"
}

mapfile -t changed_files < <(list_candidate_files "$BEFORE_SHA" "$AFTER_SHA")

log_rows=()
for file in "${changed_files[@]}"; do
  [[ -f "$file" ]] || continue
  is_image_file "$file" || continue

  if row="$(compress_file "$file")"; then
    log_rows+=("$row")
  fi
done

if (( ${#log_rows[@]} == 0 )); then
  echo "No compressible image updates detected."
  exit 0
fi

mkdir -p imgbot-logs
timestamp="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
log_file="imgbot-logs/imgbot-compression-${timestamp}.md"

{
  echo "# ImgBot Compression Report"
  echo
  echo "- Repository: \`${GITHUB_REPOSITORY:-unknown}\`"
  echo "- Generated at (UTC): \`${timestamp}\`"
  echo "- Source commit: \`${AFTER_SHA}\`"
  if [[ -n "$BEFORE_SHA" ]]; then
    echo "- Compared from: \`${BEFORE_SHA}\`"
  fi
  echo
  echo "## Optimized Files"
  echo
  echo "| File | Original Size | Optimized Size | Bytes Saved | Reduction |"
  echo "| --- | ---: | ---: | ---: | ---: |"
  for row in "${log_rows[@]}"; do
    echo "$row"
  done
} > "$log_file"

echo "Created compression log: $log_file"
