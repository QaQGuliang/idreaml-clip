#!/bin/bash
# The package's shipped dylib targets macOS 26. Rebuild its exact libgit2
# version for our macOS 13 baseline and matching experimental SHA256 ABI.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 ]]
mkdir -p build
WORK="$(mktemp -d "$PWD/build/libgit2-macos.XXXXXX")"
git clone --depth 1 --branch v1.9.7 https://github.com/libgit2/libgit2.git "$WORK/source"
cmake -S "$WORK/source" -B "$WORK/compiled" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DEXPERIMENTAL_SHA256=ON \
  -DUSE_HTTPS=SecureTransport -DUSE_SSH=OFF -DUSE_GSSAPI=OFF \
  -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=builtin -DSONAME=OFF
cmake --build "$WORK/compiled" --parallel 3
export LIBGIT2_MACOS_WORK="$WORK"
python3 - <<'PY'
from pathlib import Path
import hashlib, json, os, shutil, subprocess
from urllib.parse import urljoin, urlparse, unquote
config = Path('.dart_tool/package_config.json').resolve()
packages = json.loads(config.read_text())['packages']
package = next(p for p in packages if p['name'] == 'git2dart_binaries')
root = Path(unquote(urlparse(urljoin(config.as_uri(), package['rootUri'])).path))
work = Path(os.environ['LIBGIT2_MACOS_WORK'])
# With SONAME disabled, upstream keeps the CMake target's default output name.
libraries = list((work / 'compiled').glob('liblibgit2package.dylib'))
assert len(libraries) == 1, libraries
destination = root / 'macos/libgit2.dylib'
shutil.copy2(libraries[0], destination)
subprocess.run(['install_name_tool', '-id', '@rpath/libgit2.dylib', str(destination)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True)
dependencies = subprocess.check_output(['otool', '-L', str(destination)], text=True)
assert '/opt/homebrew/' not in dependencies and '/usr/local/' not in dependencies, dependencies
assert subprocess.check_output(['lipo','-archs',str(destination)],text=True).strip() == 'arm64'
provenance = {
    'libgit2': '1.9.7', 'minimumMacOS': '13.0', 'architecture': 'arm64',
    'experimentalSHA256': True, 'https': 'SecureTransport', 'ssh': False,
    'sourceCommit': subprocess.check_output(['git','-C',str(work/'source'),'rev-parse','HEAD'],text=True).strip(),
    'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
}
Path('build/macos-libgit2.json').write_text(json.dumps(provenance, indent=2))
print('Prepared arm64 libgit2 1.9.7 for macOS 13 using system TLS; no Homebrew runtime dependencies.')
PY
