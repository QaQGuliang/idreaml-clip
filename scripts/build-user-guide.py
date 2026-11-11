"""Build an offline guide from the same HTML and images as the product website."""
import base64
import html
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

IMAGE_TYPES = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.ico': 'image/x-icon',
    '.svg': 'image/svg+xml',
}
CSS_URL = re.compile(r'url\(\s*([\'"]?)([^)\'"\s]+)\1\s*\)', re.I)


def check_version(source, release):
    """Refuse to relabel an older website as a newer release."""
    version = release['version']
    package = f'{version}+{release["build"]}'
    versions = set(re.findall(
        r'(?<![\d.])\d+\.\d+\.\d+(?:\+\d+)?(?![\d.])', unquote(source)))
    # The website footer uses a dotted release date, not a package version.
    versions.discard(release.get('date', '').replace('-', '.'))
    if version not in versions or package not in versions or versions - {version, package}:
        raise ValueError(
            f'Website version does not match {package}: {sorted(versions)}. '
            'Update website/index.html explicitly before building the guide.')
    if re.search(r'\{\{\w+\}\}', source):
        raise ValueError('Website contains unresolved template fields.')


class OfflineGuide(HTMLParser):
    """Replace resource URLs without rewriting the website's CSS or JavaScript."""

    def __init__(self, source, website):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.website = website.resolve()
        self.offsets = [0]
        for line in source.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.replacements = []
        self.images = {}
        self.in_style = False

    def image_url(self, value):
        if value.startswith('data:image/') or value.startswith('#'):
            return value
        url = urlsplit(value)
        if url.scheme or url.netloc or not url.path or url.path.startswith('/'):
            raise ValueError(f'Guide image must be a local website asset: {value}')
        path = (self.website / unquote(url.path)).resolve()
        if not path.is_relative_to(self.website):
            raise ValueError(f'Guide image escapes website directory: {value}')
        mime = IMAGE_TYPES.get(path.suffix.lower())
        if mime is None or not path.is_file():
            raise ValueError(f'Missing or unsupported guide image: {value}')
        if path not in self.images:
            data = base64.b64encode(path.read_bytes()).decode('ascii')
            self.images[path] = f'data:{mime};base64,{data}'
        return self.images[path] + (f'#{url.fragment}' if url.fragment else '')

    def inline_css(self, value):
        if re.search(r'@import\b', value, re.I):
            raise ValueError('Offline guide requires inline CSS; @import is unsupported.')
        return CSS_URL.sub(lambda m: f'url("{self.image_url(m[2])}")', value)

    def replace_here(self, original, replacement):
        if original != replacement:
            line, column = self.getpos()
            start = self.offsets[line - 1] + column
            self.replacements.append((start, start + len(original), replacement))

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if values.get('srcset'):
            raise ValueError('Offline guide requires a single image src, not srcset.')
        if tag in {'script', 'iframe', 'audio', 'video', 'embed', 'object'} and (
                values.get('src') or values.get('data') or values.get('poster')):
            raise ValueError(f'Offline guide cannot load external {tag} resources.')
        rel = values.get('rel', '').lower().split()
        icon = tag == 'link' and any('icon' in value for value in rel)
        if tag == 'link' and values.get('href') and not icon and rel != ['canonical']:
            raise ValueError(f'Offline guide cannot load this link resource: {rel}')
        image_attrs = {'src'} if tag == 'img' else {'href', 'xlink:href'} if tag == 'image' else set()
        if icon:
            image_attrs = {'href'}
        changed = []
        for name, value in attrs:
            if value and name in image_attrs:
                value = self.image_url(value)
            elif value and name == 'style':
                value = self.inline_css(value)
            changed.append((name, value))
        if changed != attrs:
            raw = self.get_starttag_text()
            attributes = ''.join(
                f' {name}' if value is None else f' {name}="{html.escape(value, quote=True)}"'
                for name, value in changed)
            self.replace_here(raw, f'<{tag}{attributes}{" /" if raw.endswith("/>") else ""}>')
        if tag == 'style':
            self.in_style = True

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag == 'style':
            self.in_style = False

    def handle_data(self, data):
        if self.in_style:
            self.replace_here(data, self.inline_css(data))

    def build(self):
        self.feed(self.source)
        self.close()
        output = self.source
        for start, end, replacement in reversed(self.replacements):
            output = output[:start] + replacement + output[end:]
        return output


def main():
    root = Path(__file__).resolve().parents[1]
    release = json.loads((root / 'assets/release-info.json').read_text(encoding='utf-8'))
    website = root / 'website'
    source = (website / 'index.html').read_text(encoding='utf-8')
    check_version(source, release)
    builder = OfflineGuide(source, website)
    result = builder.build()
    # Only current-version outputs and the unversioned entry are refreshed.
    # Older releases, preview/candidate files and their original images are kept.
    guide = root / 'doc' / '使用指南'
    outputs = [
        guide / f'理梦剪藏-{release["version"]}-使用指南.html',
        guide / '配套资料' / '使用指南.html',
        guide / f'理梦剪藏-{release["version"]}-应用介绍与使用指南.html',
    ]
    for output in outputs:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(result, encoding='utf-8', newline='\n')
        print(output)
    print(f'{len(builder.images)} unique images embedded; {len(result.encode("utf-8")):,} bytes each')


if __name__ == '__main__':
    main()
