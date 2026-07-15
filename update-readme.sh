#!/usr/bin/env bash
#
# update-readme.sh — regenerate README.md from each skill's SKILL.md frontmatter.
#
# Scans every subdirectory containing a SKILL.md, extracts its `name` and
# `description` from the YAML frontmatter, and rewrites the whole README.md
# from the template below. Run this after adding or editing a skill.
#
# Usage: ./update-readme.sh
#
set -euo pipefail

cd "$(dirname "$0")"

README="README.md"

# --- fixed header (edit here to change the intro) ------------------------
header() {
	cat <<'EOF'
# RayZ-Skills

A collection of skills distilled from my work and daily practice.

Each skill lives in its own directory with a `SKILL.md` describing when and how
to use it, plus any supporting tools.

## Skills

EOF
}

# --- extract a frontmatter field from a SKILL.md -------------------------
# Reads only the first `---`-delimited block; prints the value of the given key.
frontmatter_field() {
	local file="$1" key="$2"
	awk -v key="$key" '
		NR == 1 && $0 == "---" { in_fm = 1; next }
		in_fm && $0 == "---"   { exit }
		in_fm {
			# match "key: value" allowing surrounding whitespace
			if ($0 ~ "^[[:space:]]*" key "[[:space:]]*:") {
				sub("^[[:space:]]*" key "[[:space:]]*:[[:space:]]*", "")
				print
				exit
			}
		}
	' "$file"
}

# --- build the skills list ----------------------------------------------
{
	header

	found=0
	# Sort directories alphabetically for stable output.
	for skill_md in $(find . -mindepth 2 -maxdepth 2 -name SKILL.md | sort); do
		dir="$(dirname "$skill_md")"
		dir="${dir#./}"

		name="$(frontmatter_field "$skill_md" name)"
		desc="$(frontmatter_field "$skill_md" description)"

		# Fall back to directory name if `name` is missing.
		[ -z "$name" ] && name="$dir"

		if [ -n "$desc" ]; then
			printf -- '- [%s](%s/SKILL.md) — %s\n' "$name" "$dir" "$desc"
		else
			printf -- '- [%s](%s/SKILL.md)\n' "$name" "$dir"
		fi
		found=1
	done

	[ "$found" -eq 0 ] && printf -- '_No skills yet._\n'
} >"$README"

echo "Wrote $README"
