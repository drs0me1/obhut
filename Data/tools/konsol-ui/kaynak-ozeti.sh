#!/bin/sh
# Prints the digest of Konsol's new interface sources (DD-258), the value `npm run derle` writes to
# ../../console/yeni/kaynak.sha256, with POSIX tools only: for every regular file under this folder except
# node_modules/, in byte order of its relative path, the line "<sha256 of the file>  <path>"; the digest
# is the sha256 of those lines. Used by the tests to see that the committed build matches its sources.
set -eu
cd -- "$(dirname -- "$0")"

if command -v sha256sum >/dev/null 2>&1; then
	digest() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
	digest() { shasum -a 256; }
else
	echo "kaynak-ozeti.sh: sha256sum ya da shasum gerekli" >&2
	exit 1
fi

files=$(find . -path ./node_modules -prune -o -type f -print | LC_ALL=C sort)
lines=""
while IFS= read -r path; do
	path=${path#./}
	case $path in
	"" | *[!A-Za-z0-9._@+/-]*)
		echo "kaynak-ozeti.sh: beklenmeyen dosya adı: $path" >&2
		exit 1
		;;
	esac
	sum=$(digest <"$path")
	lines="$lines${sum%% *}  $path
"
done <<EOF
$files
EOF

total=$(printf '%s' "$lines" | digest)
echo "${total%% *}"
