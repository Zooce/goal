#!/bin/sh
set -eu

# Map uname to a GitHub Release binary name.
os=$(uname -s)
arch=$(uname -m)
case "$os" in
Linux) os=linux ;;
Darwin) os=macos ;;
*)
    printf '%s\n' "goal: no prebuilt binary for $(uname -s); build from source (Zig 0.16)" >&2
    exit 1
    ;;
esac
case "$arch" in
x86_64 | amd64) arch=x86_64 ;;
aarch64 | arm64) arch=aarch64 ;;
*)
    printf '%s\n' "goal: no prebuilt binary for $os/$arch; build from source (Zig 0.16)" >&2
    exit 1
    ;;
esac
asset="goal-${os}-${arch}"

bindir="${GOAL_BIN:-$HOME/.local/bin}"

# GOAL_VERSION is v1.0. Unset means the latest release.
# GOAL_RELEASE_BASE replaces the GitHub download URL (a mirror or a test release).
if [ -n "${GOAL_VERSION:-}" ]; then
    case "$GOAL_VERSION" in
        v*.*) version="${GOAL_VERSION#v}" ;;
        *)
            printf '%s\n' "goal: GOAL_VERSION must look like v1.0" >&2
            exit 1
            ;;
    esac
    major="${version%%.*}"
    minor="${version#*.}"
    case "$major$minor" in
        *[!0-9]*) bad=1 ;;
        *) bad= ;;
    esac
    if [ -n "$bad" ] || [ -z "$major" ] || [ -z "$minor" ] || [ "$minor" != "${minor%%.*}" ]; then
        printf '%s\n' "goal: GOAL_VERSION must look like v1.0" >&2
        exit 1
    fi
    default_base="https://github.com/Zooce/goal/releases/download/${GOAL_VERSION}"
else
    default_base="https://github.com/Zooce/goal/releases/latest/download"
fi
base="${GOAL_RELEASE_BASE:-$default_base}"

download() {
    _url=$1
    _dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$_url" -o "$_dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$_dest" "$_url"
    else
        printf '%s\n' "goal: need curl or wget" >&2
        exit 1
    fi
}

# Fetch SHA256SUMS and the matching binary.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
printf '%s\n' "goal: downloading $asset"
download "$base/SHA256SUMS" "$tmpdir/SHA256SUMS"
download "$base/$asset" "$tmpdir/$asset"

# Check the binary against the SHA256SUMS line for this asset.
(
    cd "$tmpdir"
    line=$(grep " ${asset}$" SHA256SUMS) || {
        printf '%s\n' "goal: no checksum for $asset" >&2
        exit 1
    }
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s\n' "$line" | sha256sum -c -
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s\n' "$line" | shasum -a 256 -c -
    else
        printf '%s\n' "goal: need sha256sum or shasum" >&2
        exit 1
    fi
)

mkdir -p "$bindir"
cp "$tmpdir/$asset" "$bindir/goal"
chmod 755 "$bindir/goal"

printf '%s\n' "goal: installed $bindir/goal"
"$bindir/goal" --version
case ":$PATH:" in
*":$bindir:"*) ;;
*)
    printf '%s\n' "export PATH=\"$bindir:\$PATH\""
    ;;
esac
printf '%s\n' "next: npx skills add Zooce/goal -g"
