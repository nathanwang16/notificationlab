#!/bin/zsh
set -euo pipefail
LAB_ROOT="${0:A:h:h}"
LAB_WORK="${NOTIFICATION_LAB_WORK:-$LAB_ROOT/work}/build"
LAB_APPS="${NOTIFICATION_LAB_BUILD_APPS:-$LAB_ROOT/apps}"
mkdir -p "$LAB_WORK/module-cache" "$LAB_APPS"
for LAB_KIND in Capture Generator; do
    LAB_APP="$LAB_APPS/NotificationLab${LAB_KIND}.app"
    mkdir -p "$LAB_APP/Contents/MacOS"
    if [[ "$LAB_KIND" == Capture ]]; then
        LAB_BUNDLE="local.notificationlab.capture"
        LAB_SOURCES=("$LAB_ROOT/Sources/Core.swift" "$LAB_ROOT/Sources/Persistence.swift" "$LAB_ROOT/Sources/Configuration.swift" "$LAB_ROOT/Sources/DatabaseProbe.swift" "$LAB_ROOT/Sources/AccessibilityProbe.swift" "$LAB_ROOT/Sources/CaptureApp.swift")
    else
        LAB_BUNDLE="local.notificationlab.generator"
        LAB_SOURCES=("$LAB_ROOT/Sources/Core.swift" "$LAB_ROOT/Sources/GeneratorApp.swift")
    fi
    xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -module-cache-path "$LAB_WORK/module-cache" "${LAB_SOURCES[@]}" -o "$LAB_APP/Contents/MacOS/NotificationLab${LAB_KIND}"
    /usr/bin/python3 - "$LAB_APP" "$LAB_KIND" "$LAB_BUNDLE" <<'PY'
import pathlib,plistlib,sys
app,kind,bundle=sys.argv[1:]
info={'CFBundleIdentifier':bundle,'CFBundleExecutable':'NotificationLab'+kind,'CFBundleName':'NotificationLab '+('Sender' if kind=='Generator' else 'Capture'),'CFBundleDisplayName':'NotificationLab '+('Sender' if kind=='Generator' else 'Capture'),'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.2.0','CFBundleVersion':'2','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}
pathlib.Path(app,'Contents','Info.plist').write_bytes(plistlib.dumps(info))
PY
    codesign --force --sign - --identifier "$LAB_BUNDLE" "$LAB_APP"
    codesign --verify --strict "$LAB_APP"
    print "Built $LAB_APP"
done
