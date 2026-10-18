#!/usr/bin/env python3
"""Однократная проверенная миграция исходников; удаляется из итогового дерева."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
payload = root / '.github/source-transition.json'
if payload.exists():
    changes = []
    for item in json.loads(payload.read_text()):
        path = root / item['path']
        assert path.resolve().is_relative_to(root)
        assert item['path'].split('/')[0] in ['Sources', 'Scripts', 'Resources']
        raw = path.read_bytes()
        assert hashlib.sha256(raw).hexdigest() == item['before'], item['path']
        lines = raw.decode().splitlines(keepends=True)
        for start, end, replacement in reversed(item['edits']):
            lines[start:end] = [replacement]
        result = ''.join(lines).encode()
        assert hashlib.sha256(result).hexdigest() == item['after'], item['path']
        changes.append((path, result))
    for path, result in changes:
        path.write_bytes(result)
    payload.unlink()
    Path(__file__).unlink()
    print('SOURCE_TRANSITION_VERIFIED: все начальные и итоговые SHA-256 совпали')
