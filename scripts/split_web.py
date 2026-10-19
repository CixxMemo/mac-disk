#!/usr/bin/env python3
"""One-time split of Disk-Atlas.template.html into Resources/web/{index.html,app.css,app.js}.

The template stays untouched (the Python tool still uses it). Re-running overwrites the web files,
so only run it to regenerate from scratch; the files are edited by hand afterwards.
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root / 'Disk-Atlas.template.html').read_text()
out = root / 'Resources' / 'web'
if any((out / name).exists() for name in ('index.html', 'app.css', 'app.js')) and '--force' not in sys.argv:
    raise SystemExit('Resources/web already exists; pass --force to overwrite hand-edited files.')
out.mkdir(parents=True, exist_ok=True)

style = re.search(r'<style>\n(.*?)\n</style>', source, re.S).group(1)
original_script = re.search(r'<script>\n(.*?)\n</script>', source, re.S).group(1)
script = original_script.replace('const EMBEDDED = /*__REPORT_DATA__*/ null;\n', '')
script = re.sub(r"\nif\(EMBEDDED\)\{.*?\}\}else \$\('welcome'\)\.classList\.remove\('hidden'\);\s*$", '\n', script, flags=re.S)
if 'EMBEDDED' in script:
    raise SystemExit('EMBEDDED boot code was not removed cleanly.')

csp = ("default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
       "connect-src 'none'; font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'")
html = source.replace(style, '').replace(original_script, '')
html = re.sub(r'<style>\s*</style>', '<link rel="stylesheet" href="app.css">', html)
html = re.sub(r'<script>\s*</script>', '<script src="app.js"></script>', html)
html = re.sub(r'(<meta http-equiv="Content-Security-Policy" content=")[^"]*(">)', lambda m: m.group(1) + csp + m.group(2), html)
(out / 'app.css').write_text(style + '\n')
(out / 'app.js').write_text(script + '\n')
(out / 'index.html').write_text(html)
print('wrote', [p.name for p in sorted(out.iterdir())])
