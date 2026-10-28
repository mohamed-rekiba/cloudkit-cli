# shellcheck shell=bash
# Shared interactive picker for service helpers.

# _ck_pick <title> <header> <rows-file>
# Header and rows are '|'-separated. Auto-selects when there is a single row,
# otherwise prompts for a number. On success sets CK_PICKED to the chosen row;
# returns 1 when there are no rows or the choice is invalid.
_ck_pick() {
  local title="$1"
  local header="$2"
  local rows_file="$3"
  local count choice first

  CK_PICKED=""
  count=$(grep -c . "$rows_file" || true)

  if [ "$count" -eq 0 ]; then
    printf "%sNo running instances found.%s\n" "${RED:-}" "${NC:-}" >&2
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    CK_PICKED=$(head -n 1 "$rows_file")
    IFS='|' read -r first _ <<< "$CK_PICKED"
    printf "%sAuto-selecting the only running instance: %s%s%s\n" \
      "${GREEN:-}" "${BOLD:-}" "$first" "${NC:-}"
    return 0
  fi

  printf "\n%s%s:%s\n\n" "${BOLD_GREEN:-}" "$title" "${NC:-}"

  # Build table, pipe through column -t, then colorize with sed (as in select_profile)
  {
    printf "#|%s\n" "$header"
    printf "#|%s\n" "$header" | sed 's/[^|]/─/g'

    local line_num=1 row
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      printf "[%d]|%s\n" "$line_num" "$row"
      line_num=$((line_num + 1))
    done < "$rows_file"
  } | column -t -s '|' | sed \
    -e "1s/.*/${BOLD:-}&${NC:-}/" \
    -e "s/\(\[[[0-9]*\]\)/${BLUE:-}\1${NC:-}/g"

  printf "\n%sSelect an instance [1-%d]: %s" "${BOLD:-}" "$count" "${NC:-}"
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
    printf "%sInvalid selection.%s\n" "${RED:-}" "${NC:-}" >&2
    return 1
  fi

  CK_PICKED=$(grep . "$rows_file" | sed -n "${choice}p")
}
