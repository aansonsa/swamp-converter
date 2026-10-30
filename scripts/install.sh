#!/bin/zsh
# Installs the packaged app (from dist/SwampConverter.zip, or from the build cache) into ~/Applications and links the command-line tool `swamp`.
# Usage: scripts/install.sh [--no-cli]      Never uses sudo. Never touches /Applications. Run ./build.sh package first.
# Owner: the app module (packaging part).

setopt err_return
SCRIPT=${0:A}
PROJECT=${SCRIPT:h:h}
CACHE=${SC_CACHE:-$HOME/Library/Caches/SwampConverter}
DEST=$HOME/Applications
BIN=$HOME/.local/bin
APP_NAME="Swamp Converter.app"

src=
if [[ -d $CACHE/app/$APP_NAME ]]; then src=$CACHE/app/$APP_NAME; fi
if [[ -z $src && -f $PROJECT/dist/SwampConverter.zip ]]; then
  tmp=$(mktemp -d $CACHE/tmp/install.XXXXXX)
  ditto -x -k $PROJECT/dist/SwampConverter.zip $tmp
  src=$tmp/$APP_NAME
fi
[[ -d $src ]] || { print -u2 "install: no packaged app found. Run ./build.sh package first."; exit 1 }

mkdir -p $DEST
if [[ -d $DEST/$APP_NAME ]]; then
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p $CACHE/trash/$stamp
  mv "$DEST/$APP_NAME" "$CACHE/trash/$stamp/$APP_NAME"
  print "previous version moved to $CACHE/trash/$stamp (empty the folder yourself when you like)"
fi
ditto --norsrc --noextattr $src "$DEST/$APP_NAME"
print "installed: $DEST/$APP_NAME"

if [[ ${1:-} != --no-cli ]]; then
  mkdir -p $BIN
  ln -sfn "$DEST/$APP_NAME/Contents/MacOS/SwampConverter" $BIN/swamp
  print "command line: $BIN/swamp  (add $BIN to PATH if it is not there yet)"
fi
print "First launch: open the app once so macOS registers the Services menu items; a copy that arrived through a browser needs right-click > Open (ad-hoc signature)."
