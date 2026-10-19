#!/usr/bin/env python3
"""Read filesystem metadata only; write new Disk Atlas reports in this project."""
import argparse
import datetime as dt
import heapq
import json
import os
from pathlib import Path
import shutil
import stat
import time

CATEGORIES = ('cache', 'build', 'dependencies', 'models', 'personal', 'system')
DATA = '/System/Volumes/Data'


def display(path):
    return path[len(DATA):] or '/' if path == DATA or path.startswith(DATA + '/') else path


def classify(path, inherited):
    if inherited in ('cache', 'build', 'dependencies', 'models'):
        return inherited
    name = os.path.basename(path).lower()
    lower = display(path).lower()
    if '/applications/' in lower and (name.endswith('.app') or '.app/' in lower):
        return 'system'
    if '/.lmstudio/models' in lower or '/.ollama/models' in lower or '/.cache/huggingface' in lower:
        return 'models'
    if name in ('node_modules', '.venv', 'venv', 'bower_components'):
        return 'dependencies'
    if name in ('.next', '.nuxt', '.svelte-kit', '.turbo', '__pycache__', 'deriveddata'):
        return 'build'
    if name in ('.cache', '_cacache', 'caches', 'cache', 'gpucache', 'code cache'):
        return 'cache'
    if any(lower == p or lower.startswith(p + '/') for p in ('/applications', '/library', '/system', '/usr', '/private', '/opt')):
        return 'system'
    return inherited or 'personal'


def configure_help(html, seconds, max_entries):
    start = html.index('<div class="help-content">')
    end = html.index('</div></section>', start)
    help_text = f'''<div class="help-content">
<h3>01 — Gerçek tarama raporu</h3><p>Bu rapor yerel <b>scanner.py</b> ile oluşturuldu. HTML diske kendiliğinden erişmez. Yeniden ölçmek için proje klasöründe <code>python3 -B scanner.py</code> çalıştırılabilir. Varsayılan kapsam macOS veri birimidir; kullanıcı klasörü için <code>python3 -B scanner.py --root ~</code> kullanılır. Python 3.9+ gerekir.</p>
<h3>02 — Yalnızca dosya metaverileri</h3><p>Ad, yol, mantıksal boyut ve ayrılan bloklar ölçülür. Dosya içerikleri açılmaz. Sembolik bağlantılar ve farklı disk birimleri izlenmez. Bulut içerikleri indirilmez; materyalleşmemiş bulut klasörlerinin altına girilmez. Kaynaklara yazılmaz. Yalnızca proje içinde yeni HTML ve JSON raporları oluşturulur; reports klasörü ölçüme katılmaz.</p>
<h3>03 — Kapsam ve sınırlar</h3><p>Bu ölçümde sınır {seconds} saniye veya {max_entries:,} kayıttır. Sınıra ulaşılırsa rapor kısmi işaretlenir. Erişim engelleri ayrıca sayılır; ilk 100 hata listelenir. Parola, sudo veya yeni disk erişimi izni istenmez. Haritada her düzeyde en büyük 40 öğe tutulur; kalanlar birleştirilir. En fazla 8 düzey ayrıntı gösterilir, boyut hesabı bunun altındaki erişilebilir dosyaları da kapsar.</p>
<h3>04 — Boyutların anlamı</h3><p>Boyutlar 1024 tabanlı KiB, MiB ve GiB birimlerindedir. Dosyaya ayrılan alan ölçülür; klasörlerin kendi blokları dahil değildir. Sabit bağlantılar bir kez sayılır. APFS klonlarının ortak blokları birden fazla sayılabilir. Korumalı alanlar, farklı birimler ve anlık görüntüler kapsam dışındadır. Bu nedenle ölçülen dosyalar ile diskin toplam kullanılan alanı eşit olmak zorunda değildir. Boş alan anlık ölçümdür.</p>
<h3>05 — Yalnızca inceleme</h3><p>Kategoriler dosya yoluna göre tahmindir. İnceleme listesi silme önerisi veya kesin kazanılacak alan değildir. Boyut, gereksizliği göstermez. Bu araçta silme, taşıma veya temizlik işlemi yoktur.</p>
<h3>06 — Yerel sonuçlar</h3><p>Rapor cihazda kalır. Dış ağ bağlantısı veya izleme yoktur. JSON dosyası yollar ve dosya adları içerir. Sayfa tarayıcı depolamasına veri kaydetmez.</p>
'''
    return html[:start] + help_text + html[end:]


class Scanner:
    def __init__(self, root, seconds, max_entries):
        self.root = os.path.abspath(root)
        self.device = os.lstat(self.root).st_dev
        self.started = time.monotonic()
        self.seconds = seconds
        self.max_entries = max_entries
        self.stopped = False
        self.stats = dict.fromkeys(('entries', 'files', 'folders', 'errors', 'symlinks',
                                   'otherMounts', 'cloudPlaceholders', 'hardlinkRepeats'), 0)
        self.errors = []
        self.categories = dict.fromkeys(CATEGORIES, 0)
        self.seen_links = set()
        self.largest = []
        self.candidates = []
        self.serial = 0
        self.last_progress = self.started
        self.output_path = os.path.realpath(Path(__file__).resolve().parent / 'reports')

    def error(self, path, reason):
        self.stats['errors'] += 1
        if len(self.errors) < 100:
            self.errors.append({'path': display(path), 'reason': reason})

    def scan(self, path, depth=0, inherited=None, inside_candidate=False, metadata=None):
        now = time.monotonic()
        if self.stopped or now - self.started >= self.seconds or self.stats['entries'] >= self.max_entries:
            self.stopped = True
            return None
        if now - self.last_progress >= 10:
            print(f"{self.stats['entries']:,} records; {self.stats['errors']} skipped/error records; {display(path)}", flush=True)
            self.last_progress = now
        try:
            info = metadata if metadata is not None else os.lstat(path)
        except OSError as exc:
            self.error(path, f'{type(exc).__name__}: {exc.strerror}')
            return None
        self.stats['entries'] += 1
        if stat.S_ISLNK(info.st_mode):
            self.stats['symlinks'] += 1
            return None
        if info.st_dev != self.device:
            self.stats['otherMounts'] += 1
            return None
        category = classify(path, inherited)
        node = {'name': os.path.basename(path) or '/', 'path': display(path),
                'bytes': 0, 'logical': 0, 'category': category}
        # lstat/scandir do not open file contents or hydrate cloud placeholders.
        dataless = bool(getattr(info, 'st_flags', 0) & getattr(stat, 'SF_DATALESS', 0x40000000))
        if dataless:
            self.stats['cloudPlaceholders'] += 1
        if stat.S_ISREG(info.st_mode):
            self.stats['files'] += 1
            if info.st_nlink > 1:
                key = (info.st_dev, info.st_ino)
                if key in self.seen_links:
                    self.stats['hardlinkRepeats'] += 1
                    return None
                self.seen_links.add(key)
            node['bytes'] = info.st_blocks * 512
            node['logical'] = info.st_size
            self.categories[category] += node['bytes']
            self.serial += 1
            entry = (node['bytes'], self.serial, node)
            if len(self.largest) < 150:
                heapq.heappush(self.largest, entry)
            elif entry[:2] > self.largest[0][:2]:
                heapq.heapreplace(self.largest, entry)
            return node
        if not stat.S_ISDIR(info.st_mode):
            return None
        self.stats['folders'] += 1
        if dataless:
            # Do not enumerate an unmaterialized directory.
            self.error(path, 'Bulut klasörü: içerik indirmemek için alt öğeler taranmadı.')
            return node
        candidate = category in ('cache', 'build', 'dependencies', 'models') and not inside_candidate
        children = []
        try:
            with os.scandir(path) as entries:
                for entry in entries:
                    if self.stopped:
                        break
                    if os.path.abspath(entry.path) in (self.output_path, DATA + self.output_path):
                        continue  # Analysis outputs are outside the source measurement.
                    try:
                        child_stat = entry.stat(follow_symlinks=False)
                    except OSError as exc:
                        self.error(entry.path, f'{type(exc).__name__}: {exc.strerror}')
                        continue
                    child = self.scan(entry.path, depth + 1, category, inside_candidate or candidate, child_stat)
                    if child is not None:
                        node['bytes'] += child['bytes']
                        node['logical'] += child['logical']
                        if depth < 8 and child['bytes']:
                            children.append(child)
        except OSError as exc:
            self.error(path, f'{type(exc).__name__}: {exc.strerror}')
        if depth < 8:
            children.sort(key=lambda x: x['bytes'], reverse=True)
            kept, rest = children[:40], children[40:]
            if rest:
                kept.append({'name': f'Diğer {len(rest)} öğe', 'path': display(path),
                             'bytes': sum(x['bytes'] for x in rest),
                             'logical': sum(x['logical'] for x in rest),
                             'category': category, 'aggregate': True})
            node['children'] = kept
        if candidate and node['bytes'] >= 10 * 1024**2:
            labels = {'cache': 'Önbellek · uygulamayla doğrula', 'build': 'Derleme çıktısı · projeyle doğrula',
                      'dependencies': 'Bağımlılık · inceleme gerekli', 'models': 'AI modeli · inceleme gerekli'}
            self.candidates.append({k: v for k, v in node.items() if k != 'children'} | {
                'label': labels[category],
                'note': 'Yalnızca dosya yoluna göre sınıflandırıldı. İçerik okunmadı; gereksiz olduğu veya yeniden indirilebileceği doğrulanmadı. Alan kesin kazanım değildir.'})
        return node


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=DATA if os.path.isdir(DATA) else str(Path.home()))
    parser.add_argument('--seconds', type=int, default=900)
    parser.add_argument('--max-entries', type=int, default=5_000_000)
    args = parser.parse_args()
    project = Path(__file__).resolve().parent
    # The dashboard template is separate from generated report files.
    modern_ui = (project / 'Disk-Atlas.template.html').exists()
    template = None if modern_ui else configure_help((project / 'Disk-Atlas.html').read_text(), args.seconds, args.max_entries)
    scanner = Scanner(args.root, args.seconds, args.max_entries)
    tree = scanner.scan(scanner.root)
    if tree is None:
        raise SystemExit('Tarama kökü okunamadı; rapor oluşturulmadı.')
    disk = shutil.disk_usage(scanner.root)
    created = dt.datetime.now(dt.timezone.utc)
    report = {'schema': 1, 'app': 'Disk Atlas', 'demo': False, 'created': created.isoformat(),
              'scope': display(scanner.root), 'platform': 'darwin', 'incomplete': scanner.stopped,
              'seconds': round(time.monotonic() - scanner.started, 2),
              'disk': {'total': disk.total, 'free': disk.free, 'used': disk.used},
              'tree': tree, 'categories': scanner.categories,
              'candidates': sorted(scanner.candidates, key=lambda x: x['bytes'], reverse=True),
              'largest': [x[2] for x in sorted(scanner.largest, reverse=True)],
              'stats': scanner.stats, 'errors': scanner.errors,
              'measurement': {'unit': 'bytes', 'allocated': 'st_blocks * 512',
                              'scopeRoot': scanner.root, 'directoryBlocksIncluded': False,
                              'hardlinksCountedOnce': True, 'symlinksFollowed': False,
                              'otherVolumesFollowed': False, 'fileContentsOpened': False,
                              'treeDepth': 8, 'maxChildren': 40,
                              'caveat': 'APFS shared clone extents may be counted more than once; protected data and snapshots are outside the scan.'}}
    if modern_ui:
        from build_ui import render_report
        html = render_report(report)
    else:
        payload = json.dumps(report, ensure_ascii=False)
        embedded = payload.replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
        html = template.replace('/*__REPORT_DATA__*/ null', embedded, 1)
        if html == template:
            raise SystemExit('HTML gömme noktası bulunamadı.')
    output = project / 'reports'
    output.mkdir(exist_ok=True)
    stamp = created.strftime('%Y%m%d-%H%M%S-%f')
    json_path = output / f'disk-atlas-{stamp}.json'
    html_path = output / f'Disk-Atlas-{stamp}.html'
    with json_path.open('x') as handle:
        handle.write(json.dumps(report, ensure_ascii=False, indent=2))
    with html_path.open('x') as handle:
        handle.write(html)
    if modern_ui:
        (project / 'Disk-Atlas.html').write_text(html)
    print(json.dumps({'json': str(json_path), 'html': str(html_path), 'seconds': report['seconds'],
                      'stats': scanner.stats, 'allocatedBytes': tree['bytes'],
                      'disk': report['disk'], 'incomplete': scanner.stopped}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
