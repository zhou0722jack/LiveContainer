import difflib
import json
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
ROOT = BASE / 'SideStore'
mapping = dict(line.split('\t', 1) for line in (BASE / 'zh-dynamic.tsv').read_text().splitlines() if line)

def string_end(s, start):
    """Return a Swift string's end and preserve interpolation expressions."""
    i = start + 1
    template = ''
    expressions = []
    while i < len(s):
        if s[i] == '"':
            return i + 1, template, expressions
        if s.startswith('\\(', i):
            exp_start = i
            i += 2
            depth = 1
            while i < len(s) and depth:
                if s[i] == '"':
                    i, _, _ = string_end(s, i)
                    continue
                if s[i] == '(':
                    depth += 1
                elif s[i] == ')':
                    depth -= 1
                i += 1
            if depth:
                return len(s), template, expressions
            template += '{{' + str(len(expressions)) + '}}'
            expressions.append(s[exp_start:i])
        elif s[i] == '\\' and i + 1 < len(s):
            template += s[i:i+2]
            i += 2
        else:
            template += s[i]
            i += 1
    return i, template, expressions

display = re.compile(r'(?:\b(?:Text|Label|Button|Toggle|Section|NSLocalizedString|navigationTitle|sectionHeader|showToast)\s*\(\s*|\b(?:title|subtitle|message|detailText|text|placeholder)\s*:\s*)$')
changes = []
for p in sorted(ROOT.rglob('*.swift')):
    if 'Dependencies' in p.parts:
        continue
    old = p.read_text()
    lines = []
    for line in old.splitlines(keepends=True):
        if line.lstrip().startswith('//') or '"""' in line:
            lines.append(line)
            continue
        cursor = 0
        result = ''
        while cursor < len(line):
            start = line.find('"', cursor)
            if start < 0:
                result += line[cursor:]
                break
            end, template, expressions = string_end(line, start)
            value = line[start:end]
            if template in mapping and display.search(line[:start]):
                value = mapping[template]
                assert set(re.findall(r'\{\{\d+\}\}', value)) == set(re.findall(r'\{\{\d+\}\}', template))
                for n, expr in enumerate(expressions):
                    value = value.replace('{{' + str(n) + '}}', expr)
                value = '"' + value + '"'
            result += line[cursor:start] + value
            cursor = end
        lines.append(result)
    new = ''.join(lines)
    if new != old:
        changes.append((p, old, new))
if '--index' in sys.argv:
    print(json.dumps([str(p.relative_to(ROOT)) for p, _, _ in changes]))
    sys.exit()
parts = ['*** Begin Patch']
for p, old, new in changes:
    if str(p.relative_to(ROOT)) != sys.argv[1]:
        continue
    parts.append('*** Update File: ' + str(p))
    for line in list(difflib.unified_diff(old.splitlines(), new.splitlines(), n=3))[2:]:
        parts.append('@@' if line.startswith('@@') else line)
parts.append('*** End Patch')
print(json.dumps({'patch':'\n'.join(parts)},ensure_ascii=False))
