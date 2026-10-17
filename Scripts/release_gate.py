#!/usr/bin/env python3
"""Проверяет наличие аппаратных протоколов. Не проводит испытания и не подписывает их."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
PATTERN = re.compile(r'(public static let approved: \[ApprovedMachine\] = )\[(.*?)\]', re.S)
REQUIRED = ('native_build', 'signature_xpc', 'ui_accessibility', 'closed_lid_without_monitor',
            'displays_and_lock', 'power_changes', 'crash_recovery', 'update_and_uninstall')

def approved_source() -> tuple[str, re.Match[str]]:
    source = (ROOT / 'Sources/BoggartPlatform/HardwareValidation.swift').read_text()
    match = PATTERN.search(source)
    if not match:
        raise ValueError('Не найден единственный список проверенных конфигураций.')
    return source, match

def fingerprint() -> str:
    digest = hashlib.sha256()
    for path in sorted([*(ROOT / 'Sources').rglob('*.swift'), *(ROOT / 'Resources').rglob('*')]):
        if not path.is_file():
            continue
        content = path.read_bytes()
        if path.name == 'HardwareValidation.swift':
            content = PATTERN.sub(r'\1[]', content.decode()).encode()
        digest.update(path.relative_to(ROOT).as_posix().encode() + b'\0' + content + b'\0')
    return digest.hexdigest()

def configurations() -> list[tuple[str, str, str]]:
    _, match = approved_source()
    block = re.sub(r'//[^\n]*', '', match[2])
    item = re.compile(r'\.init\(\s*model:\s*"([A-Za-z0-9,._-]+)"\s*,\s*osBuild:\s*"([A-Za-z0-9._-]+)"\s*,\s*testReport:\s*"([^"\n]+)"\s*\)')
    entries = item.findall(block)
    if item.sub('', block).strip(' ,\n\r\t'):
        raise ValueError('Неожиданный формат списка аппаратного допуска.')
    return entries

def verify() -> list[tuple[str, str, str]]:
    entries = configurations()
    if not entries:
        raise ValueError('Выпуск заблокирован: нет ни одной аппаратно подтверждённой конфигурации.')
    seen: set[tuple[str, str]] = set()
    expected = fingerprint()
    for model, build, relative in entries:
        if (model, build) in seen:
            raise ValueError('Повторная конфигурация: ' + model + ' / ' + build)
        seen.add((model, build))
        path = (ROOT / relative).resolve()
        if ROOT / 'Docs/Отчёты' not in path.parents or path.suffix != '.json':
            raise ValueError('Протокол должен находиться в Docs/Отчёты/*.json.')
        data = json.loads(path.read_text())
        if data.get('schema') != 1 or data.get('approved') is not True or data.get('version') != '0.4.0':
            raise ValueError('Протокол не подтверждает текущий выпуск: ' + relative)
        if data.get('model') != model or data.get('osBuild') != build or data.get('sourceFingerprint') != expected:
            raise ValueError('Протокол относится к другой конфигурации или исходникам: ' + relative)
        if not data.get('acceptedBy') or not data.get('date') or not data.get('evidence'):
            raise ValueError('В протоколе нет исполнителя, даты или свидетельств: ' + relative)
        if any(data.get('checks', {}).get(key) is not True for key in REQUIRED):
            raise ValueError('Не все обязательные проверки пройдены: ' + relative)
    return entries

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fingerprint', action='store_true', help='Только отпечаток исходников; не разрешает выпуск.')
    args = parser.parse_args()
    try:
        if args.fingerprint:
            print(fingerprint())
        else:
            entries = verify()
            print(f'Аппаратный допуск: {len(entries)} конфигураций с протоколами текущих исходников.')
        return 0
    except (OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())
