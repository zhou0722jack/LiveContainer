"""Audit translated source without executing or changing app logic."""
import ast
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

BASE = Path(__file__).resolve().parent
ROOT = BASE / 'SideStore'
tree = ast.parse((BASE / 'prepare_dynamic_patch.py').read_text())
func = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'string_end')
namespace = {}
exec(compile(ast.Module(body=[func], type_ignores=[]), '<swift-string-parser>', 'exec'), namespace)
string_end = namespace['string_end']

def skeleton(source):
    i = 0
    out = ''
    literals = []
    while i < len(source):
        start = source.find('"', i)
        if start < 0:
            out += source[i:]
            break
        end, template, expressions = string_end(source, start)
        out += source[i:start] + '<string>' + ''.join(expressions)
        literals.append(template)
        i = end
    return out, literals

changed = subprocess.check_output(['git', '-C', str(ROOT), 'diff', 'HEAD', '--name-only'], text=True).splitlines()
counts = {}
for f in changed:
    p = ROOT / f
    before = subprocess.check_output(['git', '-C', str(ROOT), 'show', 'HEAD:' + f], text=True)
    after = p.read_text()
    if p.suffix == '.swift':
        before_code, before_strings = skeleton(before)
        after_code, after_strings = skeleton(after)
        # One known display-only change removes a redundant singular/plural
        # branch because both are "天" in Chinese.
        if f == 'AltWidget/Widgets/ActiveAppsWidget.swift':
            before = before.replace('Text("Expires in \\(daysRemaining) ") + (daysRemaining == 1 ? Text("day") : Text("days"))',
                                    'Text("剩余 \\(daysRemaining) 天")')
            before_code, before_strings = skeleton(before)
        assert [l.rstrip() for l in before_code.splitlines()] == [l.rstrip() for l in after_code.splitlines()], f + ': code outside display strings changed'
        assert len(before_strings) == len(after_strings), f
        for a, b in zip(before_strings, after_strings):
            if a != b:
                pattern = r'%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?(?:ll|l|z)?[@diufgsc]'
                assert re.findall(pattern, a) == re.findall(pattern, b), (f, a, b)
                assert re.findall(r'\{\{\d+\}\}', a) == re.findall(r'\{\{\d+\}\}', b), (f, a, b)
                counts[f] = counts.get(f, 0) + 1
    elif p.suffix in ['.storyboard', '.xib']:
        old_xml, new_xml = ET.fromstring(before), ET.fromstring(after)
        allowed = {'text', 'title', 'placeholder', 'headerTitle', 'footerTitle', 'prompt'}
        def canonical(element):
            return (element.tag, {k: v for k, v in element.attrib.items() if k not in allowed},
                    None if element.tag == 'string' and element.get('key') in allowed else (element.text or '').strip(),
                    [canonical(child) for child in element])
        assert canonical(old_xml) == canonical(new_xml), f + ': storyboard layout changed'
    else:
        raise AssertionError('Unexpected tracked change: ' + f)
report = {'base_commit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'],text=True).strip(),
          'changed_files': changed, 'swift_display_literal_changes': counts,
          'non_display_code': 'unchanged, except simplified Chinese widget singular/plural text',
          'printf_placeholders': 'PASS', 'swift_interpolation_expressions': 'PASS',
          'storyboard_layout_and_identifiers': 'unchanged',
          'localization_table_entries': sum(1 for l in (ROOT / 'AltStore/zh-Hans.lproj/Localizable.strings').read_text().splitlines() if ' = ' in l)}
(BASE / 'zh-source-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print('Source audit passed;',len(changed),'files;',sum(counts.values()),'Swift display literals;',report['localization_table_entries'],'resource entries.')
