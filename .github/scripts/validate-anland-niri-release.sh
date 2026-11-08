#!/usr/bin/env bash
# Validate one Anland Niri Arch ARM64 release asset directory.
#
# The layout and manifest keys mirror what install-anland-niri.sh downloads:
#   anland-niri-manifest
#   anland-niri-arch-<version>-aarch64.tar.gz
#   packages/*.pkg.tar.*
#
# Usage: validate-anland-niri-release.sh <asset-dir> <release-tag> [revision]
set -euo pipefail

die() {
    printf '[validate-anland-niri] %s\n' "$*" >&2
    exit 1
}

asset_dir="${1:?usage: validate-anland-niri-release.sh <asset-dir> <release-tag> [revision]}"
expected_tag="${2:?usage: validate-anland-niri-release.sh <asset-dir> <release-tag> [revision]}"
expected_revision="${3:-}"

manifest="$asset_dir/anland-niri-manifest"
[[ -f "$manifest" ]] || die "missing manifest: $manifest"

manifest_count() {
    awk -v key="$1" 'index($0, key "=") == 1 { count += 1 } END { print count + 0 }' "$manifest"
}

manifest_value() {
    local key="$1" count
    count="$(manifest_count "$key")"
    [[ "$count" == 1 ]] || die "manifest key '$key' must appear exactly once (found $count)"
    awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$manifest"
}

format="$(manifest_value format)"
[[ "$format" == 1 ]] || die "unsupported manifest format: $format"

release_tag="$(manifest_value release_tag)"
[[ "$release_tag" == "$expected_tag" ]] || die "manifest release_tag '$release_tag' does not match '$expected_tag'"

revision="$(manifest_value revision)"
[[ "$revision" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid revision: $revision"
[[ "$revision" != *..* ]] || die "invalid revision: $revision"
if [[ -n "$expected_revision" && "$revision" != "$expected_revision" ]]; then
    die "manifest revision '$revision' does not match '$expected_revision'"
fi

archive_name="$(manifest_value arch)"
[[ "$archive_name" =~ ^anland-niri-arch-[A-Za-z0-9.+~_-]+-aarch64\.tar\.gz$ ]] || \
    die "invalid Arch archive name: $archive_name"
[[ "$archive_name" != *..* ]] || die "invalid Arch archive name: $archive_name"

archive_path="$asset_dir/$archive_name"
[[ -f "$archive_path" ]] || die "missing Arch archive: $archive_path"

archive_sha256="$(manifest_value arch_sha256)"
[[ "$archive_sha256" =~ ^[0-9a-f]{64}$ ]] || die "invalid arch_sha256: $archive_sha256"
actual_sha256="$(sha256sum "$archive_path" | awk '{ print $1 }')"
[[ "$actual_sha256" == "$archive_sha256" ]] || \
    die "arch_sha256 mismatch: manifest=$archive_sha256 actual=$actual_sha256"

archive_size="$(stat -c '%s' "$archive_path")"
(( archive_size <= 512 * 1024 * 1024 )) || die "archive exceeds the 512 MiB download limit"

members="$(tar -tzf "$archive_path")" || die "not a readable tar.gz: $archive_path"
[[ -n "$members" ]] || die "empty tar.gz: $archive_path"

while IFS= read -r entry; do
    case "$entry" in
        /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*)
            die "archive contains an unsafe path: $entry"
            ;;
        anland-niri-packages/arch/*) ;;
        *)
            die "archive member is outside anland-niri-packages/arch/: $entry"
            ;;
    esac
done <<< "$members"

LC_ALL=C tar -tvzf "$archive_path" | awk -v maximum="$((2 * 1024 * 1024 * 1024))" '
    {
        entry_type = substr($1, 1, 1)
        if (entry_type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) {
            exit 1
        }
        total += $3
        if (total > maximum) {
            exit 1
        }
    }
' || die "archive contains disallowed entries or exceeds the 2 GiB extraction limit"

package_members="$(grep -E '^anland-niri-packages/arch/[^/]+\.pkg\.tar\.[a-z0-9]+$' <<< "$members" || true)"
package_count="$(grep -c . <<< "$package_members" || true)"
[[ "$package_count" == 2 ]] || die "expected exactly two packages in the archive, found $package_count"

grep -Eq '^anland-niri-packages/arch/niri-anland-[^/]+\.pkg\.tar\.[a-z0-9]+$' <<< "$package_members" || \
    die "archive is missing the niri-anland package"
grep -Eq '^anland-niri-packages/arch/xorg-xwayland-[^/]+\.pkg\.tar\.[a-z0-9]+$' <<< "$package_members" || \
    die "archive is missing the xorg-xwayland package"

[[ -d "$asset_dir/packages" ]] || die "missing packages directory: $asset_dir/packages"
package_files="$(find "$asset_dir/packages" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)"
[[ "$(grep -c . <<< "$package_files" || true)" == 2 ]] || \
    die "expected exactly two loose package files in $asset_dir/packages"

while IFS= read -r member; do
    base="${member#anland-niri-packages/arch/}"
    [[ -f "$asset_dir/packages/$base" ]] || die "archived package has no matching file: $base"
    member_sha256="$(tar -xOzf "$archive_path" "$member" | sha256sum | awk '{ print $1 }')"
    file_sha256="$(sha256sum "$asset_dir/packages/$base" | awk '{ print $1 }')"
    [[ "$member_sha256" == "$file_sha256" ]] || die "archived package differs from file: $base"
done <<< "$package_members"

printf '[validate-anland-niri] OK: %s (%s), revision %s\n' "$archive_name" "$archive_sha256" "$revision"
