#!/bin/zsh
# Packaging, sourced by build.sh ("./build.sh package" / "./build.sh run"). Owner: the app module (packaging part).
# Contract with build.sh: the variables PROJECT, CACHE, STAMP and the functions die(), trash_path() exist; this file defines package_app() and sets PACKAGED_APP.
#
# Policy (spec/platform.md 9): sources live on the exFAT drive; everything is assembled and signed in the build cache on APFS; codesign never runs on the exFAT volume
# (it fails there); the dist/ folder gets a ZIP made with ditto (the portable artefact: no ._ files, no __MACOSX, valid signature) and an .app copied with ditto.
# The owner's icon Resources/AppIcon.icns is copied AS IS (never regenerated). No tools are bundled (Resources/tools is copied only if it holds files).

package_app() {
  local binary=$1 config=${2:-release} dist=${3:-dist}
  [[ -x $binary ]] || die "package: no binary at $binary (build first)"
  local version=${SC_VERSION:-0.1.8}    # bump this default with every round of changes that reaches a fresh dist build; SC_VERSION overrides it for one-off builds
  local build=${SC_BUILD:-$(date +%Y%m%d%H%M)}
  local app=$CACHE/app/"Swamp Converter.app"
  local res=$PROJECT/Resources

  [[ -f $res/Info.plist.template ]] || die "package: Resources/Info.plist.template is missing"
  [[ -f $res/AppIcon.icns ]] || die "package: Resources/AppIcon.icns is missing (the owner's icon is never regenerated)"

  trash_path $app
  mkdir -p $app/Contents/MacOS $app/Contents/Resources || die "package: cannot create the bundle in $CACHE/app"
  cp $binary $app/Contents/MacOS/SwampConverter || die "package: cannot copy the binary"
  if [[ $config == release ]]; then
    strip -x $app/Contents/MacOS/SwampConverter 2>/dev/null || print -u2 "package: strip failed (continuing)"
  fi

  sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build/" $res/Info.plist.template > $app/Contents/Info.plist
  plutil -lint $app/Contents/Info.plist >/dev/null || die "package: Info.plist does not lint"
  print -n "APPL????" > $app/Contents/PkgInfo
  cp $res/AppIcon.icns $app/Contents/Resources/AppIcon.icns
  # About says "the list of adapted open-source code is in THIRD-PARTY-NOTICES.md": ship the licence and that list inside the app too.
  for f in LICENSE THIRD-PARTY-NOTICES.md; do [[ -f $PROJECT/$f ]] && cp $PROJECT/$f $app/Contents/Resources/$f; done

  local lp f
  for lp in $res/*.lproj(N); do
    [[ -d $lp ]] || continue
    mkdir -p $app/Contents/Resources/${lp:t}
    for f in $lp/*(N.); do [[ ${f:t} == ._* ]] || cp $f $app/Contents/Resources/${lp:t}/; done
  done
  if [[ -d $res/tools ]] && [[ -n "$(find $res/tools -type f -not -name '._*' -not -name '.DS_Store' 2>/dev/null | head -n 1)" ]]; then
    mkdir -p $app/Contents/Resources/tools
    ditto --norsrc --noextattr --noqtn $res/tools $app/Contents/Resources/tools
    find $app/Contents/Resources/tools -name '._*' -delete 2>/dev/null
  fi

  codesign --force --sign - --timestamp=none $app >/dev/null 2>&1 || die "package: ad-hoc codesign failed"
  codesign --verify --deep --strict $app 2>&1 || die "package: the signature does not verify"
  PACKAGED_APP=$app

  local size_kb=$(du -sk $app | cut -f1)
  print -- "assembled: $app ($(( size_kb / 1024 )).$(( (size_kb % 1024) * 10 / 1024 )) MB, $config, version $version build $build, ad-hoc signed)"
  if (( size_kb > 12288 )); then print -u2 "WARNING: the bundle is larger than the 12 MB budget"; fi

  if [[ $dist == dist ]]; then
    local out=$PROJECT/dist
    mkdir -p $out || die "package: cannot create $out"
    # The ZIP is the artefact to hand around; it is built from the clean APFS copy.
    local zip=$out/SwampConverter.zip
    [[ -e $zip ]] && trash_path $zip
    ditto -c -k --norsrc --noextattr --keepParent $app $zip || die "package: zip failed"
    # The .app copy on the exFAT drive: ditto (never cp -R); the volume adds ._ sidecars and cannot hold a verifiable seal, so treat it as a convenience copy.
    [[ -d $out/"Swamp Converter.app" ]] && trash_path $out/"Swamp Converter.app"
    ditto --norsrc --noextattr --noqtn $app $out/"Swamp Converter.app" || die "package: dist copy failed"
    # The cache copy and the dist copy share one CFBundleIdentifier; if Launch Services ever indexed the cache copy (e.g. a prior "./build.sh run"), two
    # live registrations of the same identifier confuse SMAppService.mainApp into status .notFound, so "open at login" silently never registers. Only the
    # dist copy is meant to be used, so forget the cache path here every time (metadata only: the file itself is untouched).
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u $app >/dev/null 2>&1
    print -- "dist: $zip ($(du -h $zip | cut -f1 | tr -d ' ')) and $out/Swamp Converter.app"
    print -- "      Install from the ZIP (unzip with ditto -x -k or Finder). A quarantined copy needs System Settings > Privacy & Security > Open Anyway once (ad-hoc signature)."
  fi
}
