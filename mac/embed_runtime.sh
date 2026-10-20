#!/bin/bash
set -euo pipefail
: "${PATCHBRIDGE_ROOT:?}" "${PATCHBRIDGE_PAYLOAD:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}"
source_contents="$PATCHBRIDGE_PAYLOAD/Contents"
target_contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
[ -f "$source_contents/Frameworks/Python" ]
mkdir -p "$target_contents/Frameworks" "$target_contents/MacOS" "$target_contents/Resources"
/usr/bin/ditto "$source_contents/Frameworks" "$target_contents/Frameworks"
for directory in Python Helper Licenses; do
    /usr/bin/ditto "$source_contents/Resources/$directory" "$target_contents/Resources/$directory"
done
/bin/cp "$source_contents/MacOS/patchbridge-helper" "$target_contents/MacOS/patchbridge-helper"
# Xcode signs the host after this phase. Sign every nested Mach-O with the same identity.
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
    : "${EXPANDED_CODE_SIGN_IDENTITY:?No signing identity selected}"
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$target_contents/Frameworks/Python"
    while IFS= read -r -d '' library; do
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$library"
    done < <(/usr/bin/find "$target_contents/Resources" -name '*.so' -type f -print0)
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --entitlements "$PATCHBRIDGE_ROOT/mac/Helper.entitlements" "$target_contents/MacOS/patchbridge-helper"
fi
