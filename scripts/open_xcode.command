#!/bin/zsh
# Finder-launched Xcode may not inherit Homebrew's PATH, hiding git-lfs from SwiftPM.
set -eu
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
if ! command -v git-lfs >/dev/null 2>&1; then
    print 'Git LFS is required. Install it with: brew install git-lfs'
    exit 1
fi
if pgrep -x Xcode >/dev/null 2>&1; then
    print 'Quit Xcode with Command-Q first, then run this launcher again so it inherits the correct PATH.'
    exit 1
fi
exec /Applications/Xcode.app/Contents/MacOS/Xcode "$PROJECT_ROOT/ios/JoeMobile.xcodeproj"
