#!/usr/bin/env python3
"""Build a self-contained local dashboard from existing metadata; never scan or alter source files."""
import argparse
import datetime as dt
import json
from pathlib import Path

PROJECT = Path(__file__).resolve().parent


def compact_tree(node):
    result = {k: node[k] for k in ('name', 'path', 'bytes', 'logical', 'category', 'aggregate') if k in node}
    children = node.get('children', [])
    if children:
        ordered = sorted(children, key=lambda x: x['bytes'], reverse=True)
        keep = [x for i, x in enumerate(ordered) if i < 16 and (i < 3 or x['bytes'] >= 2 * 1024**2)]
        kept_ids = {id(x) for x in keep}
        rest = [x for x in ordered if id(x) not in kept_ids]
        result['children'] = [compact_tree(x) for x in keep]
        if rest:
            result['children'].append({'name': f'Diğer {len(rest)} öğe', 'path': node['path'],
                                       'bytes': sum(x['bytes'] for x in rest),
                                       'logical': sum(x.get('logical', 0) for x in rest),
                                       'category': node['category'], 'aggregate': True})
    return result


def prepare_report(report):
    index = {}

    def visit(node):
        if not node.get('aggregate'):
            index[node['path']] = node
        for child in node.get('children', []):
            visit(child)

    visit(report['tree'])
    users = index.get('/Users', {}).get('children', [])
    home = max((x for x in users if not x.get('aggregate')), key=lambda x: x['bytes'], default=report['tree'])
    home_path = home['path']
    specs = [
        ('/Library/Caches', 'Uygulama önbellekleri', 'cache', 'Spotify, tarayıcılar ve uygulama güncelleyicilerinin verileri. Alt klasörleri haritada ayrı ayrı keşfedebilirsin.'),
        ('/.npm/_cacache', 'npm önbelleği', 'cache', 'JavaScript paket yöneticisinin yerel indirme önbelleği. Kullanım durumu ve yeniden indirilebilirlik kontrol edilmedi.'),
        ('/.gradle/caches', 'Gradle önbellekleri', 'cache', 'Android ve Java projelerinin Gradle verileri. Bu satır .gradle klasörünün tamamını kapsamaz.'),
        ('/Library/Developer/CoreSimulator', 'iOS simülatör verileri', 'review', 'Simülatör ortamları ve paylaşılan önbellekler. Bunlar Xcode uygulamasından ayrı bir konumda.'),
        ('/Library/Android/sdk', 'Android SDK', 'review', 'Android geliştirme araçları, platformlar ve sistem imajları. Kullandığın projeler bu bileşenlere bağlı olabilir.'),
        ('/.android/avd', 'Android sanal cihazları', 'review', 'Sanal cihaz diskleri, kullanıcı verileri ve anlık durum kayıtları. SDK klasöründen ayrı ölçüldü.'),
        ('/Library/Application Support/Claude', 'Claude uygulama verileri', 'review', 'Yerel uygulama verileri ve sanal makine imajı. En büyük tek dosyanın ayrıntıları Büyük dosyalar bölümünde.'),
        ('/.vscode/extensions', 'VS Code eklentileri', 'review', 'Kurulu eklentiler ve birlikte gelen araçlar. Eklentilerin gerekli olup olmadığı ölçülmedi.'),
        ('/Library/Application Support/Google', 'Google uygulama verileri', 'review', 'Tarayıcı profilleri, uygulama bileşenleri ve yerel model verileri. Normal önbellek klasöründen ayrı bir konum.'),
        ('/.lmstudio', 'LM Studio bileşenleri', 'review', 'Ağırlıklı olarak çalışma bileşenleri ve eklentiler. Klasörün tamamı indirilmiş AI modeli olarak değerlendirilmez.'),
        ('/Downloads', 'İndirilenler', 'review', 'İndirilen dosyalar ve kurulum paketleri. Dosyaların kopya veya gereksiz olduğu doğrulanmadı.'),
    ]
    findings = []
    for suffix, name, group, note in specs:
        node = index.get(home_path + suffix)
        if node and node['bytes']:
            findings.append({k: node[k] for k in ('path', 'bytes', 'category')} |
                            {'name': name, 'group': group, 'note': note})
    # Keep rebuild/dependency findings outside the curated parent folders.
    for item in report['candidates']:
        if item['bytes'] < 150 * 1024**2:
            continue
        if any(item['path'] == x['path'] or item['path'].startswith(x['path'] + '/') for x in findings):
            continue
        findings.append({k: item[k] for k in ('name', 'path', 'bytes', 'category', 'note')} |
                        {'group': 'cache' if item['category'] in ('cache', 'build') else 'review'})
    result = {k: v for k, v in report.items() if k not in ('tree', 'ui')}
    result['tree'] = compact_tree(report['tree'])
    result['ui'] = {'homePath': home_path,
                    'findings': sorted(findings, key=lambda x: x['bytes'], reverse=True)}
    return result


def render_report(report):
    template = (PROJECT / 'Disk-Atlas.template.html').read_text()
    payload = json.dumps(prepare_report(report), ensure_ascii=False, separators=(',', ':'))
    payload = payload.replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e')
    payload = payload.replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    marker = '/*__REPORT_DATA__*/ null'
    if template.count(marker) != 1:
        raise ValueError('The dashboard must contain exactly one report marker.')
    return template.replace(marker, payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--snapshot', action='store_true', help='Also save a new version in reports/.')
    args = parser.parse_args()
    source = args.report or max((PROJECT / 'reports').glob('disk-atlas-*.json'))
    report = json.loads(source.read_text())
    html = render_report(report)
    primary = PROJECT / 'Disk-Atlas.html'
    primary.write_text(html)
    output = None
    if args.snapshot:
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S-%f')
        output = PROJECT / 'reports' / f'Disk-Atlas-UI-{stamp}.html'
        output.write_text(html)
    print(json.dumps({'dashboard': str(primary), 'snapshot': str(output) if output else None, 'source': str(source),
                      'htmlBytes': len(html.encode())}, ensure_ascii=False))


if __name__ == '__main__':
    main()
