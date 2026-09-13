#!/usr/bin/env bash
# image-inventory.sh - The image families published by a Box release.
#
# This file is sourced by release tooling. Keep it free of shell options and
# side effects so callers retain control of their execution environment.

# label|suffix. The suffix is appended to both the GHCR and Docker Hub image
# names. These three families are built by the combo workflows.
COMBO_IMAGES=(
  "Full Box|"
  "Essentials|-essentials"
  "JS|-js"
)

# Must stay in sync with the `language:` matrix in release-languages.yml.
LANGUAGE_IMAGES=(
  "Python|-python"
  "Go|-go"
  "Rust|-rust"
  "Java|-java"
  "Kotlin|-kotlin"
  "Ruby|-ruby"
  "PHP|-php"
  "Perl|-perl"
  "Swift|-swift"
  "Lean|-lean"
  "Rocq|-rocq"
)

# Every combo and language image also has a Docker-in-Docker variant.
image_inventory_dind_entries() {
  local entry
  for entry in "${COMBO_IMAGES[@]}" "${LANGUAGE_IMAGES[@]}"; do
    printf '%s + dind|%s-dind\n' "${entry%%|*}" "${entry#*|}"
  done
}

mapfile -t DIND_IMAGES < <(image_inventory_dind_entries)

# image_inventory_entries - label|suffix for all 28 published image families.
image_inventory_entries() {
  local entry
  for entry in "${COMBO_IMAGES[@]}" "${LANGUAGE_IMAGES[@]}" "${DIND_IMAGES[@]}"; do
    printf '%s\n' "$entry"
  done
}

# image_inventory_suffixes - suffix for every published image family.
image_inventory_suffixes() {
  local entry
  while IFS= read -r entry; do
    printf '%s\n' "${entry#*|}"
  done < <(image_inventory_entries)
}
