"""Build the standalone guide; its source already contains every image."""
from pathlib import Path
import html
import json
import re

root = Path(__file__).resolve().parents[1]
release = json.loads((root / 'assets' / 'release-info.json').read_text(encoding='utf-8'))
source = (root / 'scripts/templates/user-guide.html.in').read_text(encoding='utf-8')
values = {
    'version': html.escape(release['version']),
    'date': html.escape(release['date']),
    'changes': ''.join(f'<li>{html.escape(item)}</li>' for item in release['changes']),
    'knownIssues': ''.join(f'<p>{html.escape(item)}</p>' for item in release['knownIssues']),
}
for key, value in values.items():
    source = source.replace('{{' + key + '}}', value)
assert not re.search(r'\{\{\w+\}\}', source), 'Unresolved template field'
output = root / 'doc' / f'Idreaml-Clip-{release["version"]}-使用指南.html'
output.write_text(source, encoding='utf-8')
# This previously shared path must also work when opened directly or copied.
# Keep the build-only template under scripts with an .in extension instead.
legacy_output = root / 'doc/guide-assets/guide.template.html'
legacy_output.parent.mkdir(parents=True, exist_ok=True)
legacy_output.write_text(source, encoding='utf-8')
print(f'{output}\n{output.stat().st_size:,} bytes; all images embedded')
