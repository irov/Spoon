#!/bin/bash
set -euo pipefail

SOURCE_DIR="$SRCROOT/Vendor/Toolchain"
CONTENTS_DIR="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"

if [[ ! -d "$SOURCE_DIR" ]]; then
  if [[ "$CONFIGURATION" == "Release" ]]; then
    echo "error: Release builds require Vendor/Toolchain. Run Tools/vendor-toolchain.sh." >&2
    exit 2
  fi
  echo "warning: Bundled SVN toolchain is absent; Debug will use /usr/bin/svn." >&2
  exit 0
fi

mkdir -p "$CONTENTS_DIR/Helpers" "$CONTENTS_DIR/Libraries" "$CONTENTS_DIR/Resources/ThirdPartyLicenses"
ditto "$SOURCE_DIR/Helpers" "$CONTENTS_DIR/Helpers"
ditto "$SOURCE_DIR/Libraries" "$CONTENTS_DIR/Libraries"
ditto "$SOURCE_DIR/Licenses" "$CONTENTS_DIR/Resources/ThirdPartyLicenses"
cp "$SOURCE_DIR/SHA256SUMS" "$CONTENTS_DIR/Resources/ThirdPartyLicenses/Toolchain-SHA256SUMS.txt"
cp "$SOURCE_DIR/CONTENT-SHA256SUMS" "$CONTENTS_DIR/Resources/ThirdPartyLicenses/Toolchain-Content-SHA256SUMS.txt"
cp "$SOURCE_DIR/VERSIONS.txt" "$CONTENTS_DIR/Resources/ThirdPartyLicenses/Toolchain-VERSIONS.txt"
cp "$BUILT_PRODUCTS_DIR/SpoonSVNRunner" "$CONTENTS_DIR/Helpers/svn"
chmod 0755 "$CONTENTS_DIR/Helpers/svn"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  for library in "$CONTENTS_DIR"/Libraries/*; do
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$library"
  done
  for helper in "$CONTENTS_DIR"/Helpers/*; do
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none \
      --options runtime --entitlements "$SRCROOT/Config/Helper.entitlements" "$helper"
  done
fi
