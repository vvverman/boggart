#!/usr/bin/env python3
"""Статические проверки комплекта. Не заменяют компиляцию с Apple SDK."""
import pathlib
import plistlib
import re
root = pathlib.Path(__file__).resolve().parent.parent
sources = list((root / 'Sources').rglob('*.swift'))
text = '\n'.join(p.read_text() for p in sources)
views = (root / 'Sources/BoggartApp/Views.swift').read_text()
assert len(re.findall(r'\bToggle\(', views)) == 2, 'В настройках должно быть два переключателя.'
for forbidden in ['SMJobBless(', 'setSleepDisabled(record.originalDisabled)', 'CGEventCreateMouseEvent(', 'maxDuration', 'extensionCapacity']:
    assert forbidden not in text, forbidden
adapter = (root / 'Sources/BoggartHelper/PMSetAdapter.swift').read_text()
assert 'return ["sleepnow"]' not in adapter
assert '["displaysleepnow"]' in adapter
assert 'setConnectionCodeSigningRequirement' in text
assert 'setCodeSigningRequirement' in text
assert 'SMAppService.daemon' in text
assert 'mach_continuous_time()' in text
assert 'case .disableSleep: return ["-a", "disablesleep", "1"]' in adapter
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
job = plistlib.loads((root / 'Resources/local.boggart.helper.plist').read_bytes())
assert info['LSUIElement'] is True
assert info['CFBundleShortVersionString'] == '0.4.1'
assert info['BoggartRecoverySchema'] == 3
assert info['BoggartProtocolVersion'] == 4
assert info['BoggartHardwareTesting'] is False
assert 'Отключить помощник' not in views
assert 'DisclosureGroup("Диагностика"' in views
assert 'DisclosureGroup("Последние сессии"' in views
assert 'lastAbnormalSummary' in views
assert 'content.sound' not in text
assert 'try history.append' not in (root / 'Sources/BoggartCore/SessionController.swift').read_text()
assert 'historyWarning' in text and 'BestEffortHistory' in text
assert 'prepareMaintenance' in text and 'cancelMaintenance' in text
assert job['BundleProgram'] == 'Contents/MacOS/BoggartHelper'
assert job['KeepAlive'] is True and job['UserName'] == 'root'
assert job['MachServices']['local.boggart.helper'] is True
assert 'Program' not in job and 'ProgramArguments' not in job
print(f'Статическая проверка: {len(sources)} Swift-файлов, два переключателя, SMAppService/XPC, конфигурация комплекта — без ошибок.')
