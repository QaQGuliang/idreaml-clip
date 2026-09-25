"""Validate metadata and arm64 support, then thin copied release binaries."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

app = Path(os.environ['PACKAGE_APP']).resolve()
output = Path(os.environ['PACKAGE_OUTPUT'])
release = json.loads(Path('assets/release-info.json').read_text(encoding='utf-8'))
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleShortVersionString'] == release['version']
assert str(info['CFBundleVersion']) == str(release['build'])
assert info['LSMinimumSystemVersion'] == '13.0'

def run(*args):
    return subprocess.check_output(args, text=True).strip()

binaries = []
for path in sorted(app.rglob('*')):
    if not path.is_file() or path.is_symlink():
        continue
    if 'Mach-O' not in run('file', '-b', str(path)):
        continue
    archs = run('lipo', '-archs', str(path)).split()
    assert 'arm64' in archs, f'Missing arm64: {path.relative_to(app)} ({archs})'
    if archs != ['arm64']:
        temporary = path.with_name(path.name + '.arm64')
        subprocess.run(['lipo', str(path), '-thin', 'arm64', '-output', str(temporary)], check=True)
        temporary.chmod(path.stat().st_mode)
        temporary.replace(path)
    assert run('lipo', '-archs', str(path)) == 'arm64'
    load_commands = run('otool', '-l', str(path))
    minimums = re.findall(r'\bminos\s+([\d.]+)', load_commands)
    for minimum in minimums:
        assert tuple(int(v) for v in minimum.split('.')[:2]) <= (13, 0), \
            f'{path.relative_to(app)} requires macOS {minimum}, above declared 13.0'
    binaries.append({'path': str(path.relative_to(app)), 'architecture': 'arm64', 'minimumOS': minimums})
assert binaries, 'No native code found'
metadata = {
    'version': release['version'], 'build': release['build'],
    'architecture': 'arm64', 'minimumMacOS': '13.0',
    'signing': 'ad-hoc', 'notarized': False,
    'commit': run('git', 'rev-parse', 'HEAD'),
    'flutter': json.loads(run('flutter', '--version', '--machine')),
    'libgit2': json.loads(Path('build/macos-libgit2.json').read_text()),
    'binaries': binaries,
    'limitations': ['Text capture only on macOS', 'Automatic paste not implemented on macOS',
                    'Cloud credential storage not implemented on macOS'],
}
(output / 'build-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding='utf-8')
print(f'Checked {len(binaries)} arm64 binaries; deployment target macOS 13.0')
