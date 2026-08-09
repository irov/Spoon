#!/bin/zsh
set -euo pipefail
setopt KSH_ARRAYS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${TOOLCHAIN_OUTPUT_DIR:-$PROJECT_DIR/Vendor/Toolchain}"
SVN_SOURCE="${SVN_SOURCE:-/opt/homebrew/bin/svn}"

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Refusing to replace existing $OUTPUT_DIR" >&2
  echo "Move it aside explicitly before regenerating the pinned toolchain." >&2
  exit 2
fi

if [[ ! -x "$SVN_SOURCE" ]]; then
  echo "Missing executable SVN_SOURCE: $SVN_SOURCE" >&2
  exit 2
fi

SVN_VERSION="$($SVN_SOURCE --version --quiet)"
if [[ "$SVN_VERSION" != "1.14.5" ]]; then
  echo "Expected Subversion 1.14.5, found $SVN_VERSION" >&2
  exit 2
fi
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spoon-toolchain.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Helpers" "$STAGING_DIR/Libraries" "$STAGING_DIR/Licenses"

cp "$SVN_SOURCE" "$STAGING_DIR/Helpers/svn-core"
chmod 0755 "$STAGING_DIR/Helpers/svn-core"

declare -a QUEUE=("$STAGING_DIR/Helpers/svn-core")
declare -A COPIED_DEPENDENCIES=()

queue_index=0
while (( queue_index < ${#QUEUE[@]} )); do
  binary="${QUEUE[$queue_index]}"
  queue_index=$((queue_index + 1))
  while IFS= read -r dependency; do
    [[ "$dependency" == /opt/homebrew/* ]] || continue
    resolved="$(realpath "$dependency")"
    basename="$(basename "$resolved")"
    destination="$STAGING_DIR/Libraries/$basename"
    if [[ -n "${COPIED_DEPENDENCIES[$resolved]:-}" ]]; then
      continue
    fi
    if [[ -e "$destination" ]]; then
      if ! cmp -s "$resolved" "$destination"; then
        echo "Dependency basename collision: $resolved -> $basename" >&2
        exit 2
      fi
    else
      cp "$resolved" "$destination"
      chmod 0755 "$destination"
      QUEUE+=("$destination")
    fi
    COPIED_DEPENDENCIES[$resolved]="$basename"
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done

for binary in "$STAGING_DIR"/Helpers/* "$STAGING_DIR"/Libraries/*; do
  if [[ "$binary" == "$STAGING_DIR"/Libraries/* ]]; then
    install_name_tool -id "@loader_path/$(basename "$binary")" "$binary" 2>/dev/null
    relative_prefix="@loader_path"
  else
    relative_prefix="@loader_path/../Libraries"
  fi
  while IFS= read -r dependency; do
    [[ "$dependency" == /opt/homebrew/* ]] || continue
    resolved="$(realpath "$dependency")"
    basename="${COPIED_DEPENDENCIES[$resolved]:-$(basename "$resolved")}"
    install_name_tool -change "$dependency" "$relative_prefix/$basename" "$binary" 2>/dev/null
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done

# Rewriting Mach-O load commands invalidates the Homebrew signatures. Give every
# nested binary a valid ad-hoc signature so the staged toolchain can be executed
# and verified before Xcode replaces it with the distribution identity.
for library in "$STAGING_DIR"/Libraries/*; do
  codesign --force --sign - --timestamp=none "$library" 2>/dev/null
done
for helper in "$STAGING_DIR"/Helpers/*; do
  # The distribution build re-signs helpers with the app identity and inherited
  # sandbox entitlement. Staging uses a plain ad-hoc signature so binaries remain
  # directly executable for the preflight check below.
  codesign --force --sign - --timestamp=none "$helper" 2>/dev/null
done


"$STAGING_DIR/Helpers/svn-core" --version --quiet | grep -qx "1.14.5"

for binary in "$STAGING_DIR"/Helpers/* "$STAGING_DIR"/Libraries/*; do
  if nm "$binary" 2>/dev/null | awk '{print $NF}' | grep -qx '___progname'; then
    echo "Forbidden private API reference in $binary: ___progname" >&2
    exit 2
  fi
done

curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/subversion/1.14.x/LICENSE' \
  --output "$STAGING_DIR/Licenses/Subversion-LICENSE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/subversion/1.14.x/NOTICE' \
  --output "$STAGING_DIR/Licenses/Subversion-NOTICE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/apr/1.7.x/LICENSE' \
  --output "$STAGING_DIR/Licenses/APR-LICENSE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/apr/1.7.x/NOTICE' \
  --output "$STAGING_DIR/Licenses/APR-NOTICE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/apr-util/1.6.x/LICENSE' \
  --output "$STAGING_DIR/Licenses/APR-Util-LICENSE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/apr-util/1.6.x/NOTICE' \
  --output "$STAGING_DIR/Licenses/APR-Util-NOTICE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/lz4/lz4/v1.10.0/lib/LICENSE' \
  --output "$STAGING_DIR/Licenses/LZ4-LICENSE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/openssl/openssl/openssl-3.6.3/LICENSE.txt' \
  --output "$STAGING_DIR/Licenses/OpenSSL-LICENSE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/apache/serf/1.3.10/LICENSE' \
  --output "$STAGING_DIR/Licenses/Serf-LICENSE.txt"
curl --fail --silent --show-error --location \
  'https://raw.githubusercontent.com/JuliaStrings/utf8proc/v2.11.3/LICENSE.md' \
  --output "$STAGING_DIR/Licenses/utf8proc-LICENSE.md"
curl --fail --silent --show-error --location \
  'https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt' \
  --output "$STAGING_DIR/Licenses/Gettext-libintl-COPYING.LIB.txt"

echo "Subversion $SVN_VERSION" > "$STAGING_DIR/VERSIONS.txt"
(cd "$STAGING_DIR" && find Helpers Libraries Licenses VERSIONS.txt -type f -print0 | sort -z | xargs -0 shasum -a 256) \
  > "$STAGING_DIR/SHA256SUMS"
xcrun swift "$PROJECT_DIR/Tools/generate-content-checksums.swift" \
  "$STAGING_DIR" "$STAGING_DIR/CONTENT-SHA256SUMS"

mkdir -p "$(dirname "$OUTPUT_DIR")"
mv "$STAGING_DIR" "$OUTPUT_DIR"
trap - EXIT
echo "Vendored toolchain written to $OUTPUT_DIR"
