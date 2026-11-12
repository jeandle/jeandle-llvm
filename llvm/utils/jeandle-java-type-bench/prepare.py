#!/usr/bin/env python3
"""Restore the frozen opt corpus and replace historical paths with relative paths."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parent / 'inputs'

def main():
    hashes = json.loads((ROOT / 'SHA256.json').read_text())
    for name, expected in hashes.items():
        if name.startswith('opt-inputs/'):
            continue
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'frozen input changed: {name}')
    target = ROOT / 'opt-inputs'
    if target.exists():
        raise RuntimeError(f'{target} already exists; use a fresh suite copy')
    with tarfile.open(ROOT / 'opt-inputs.tgz') as archive:
        # Only plain files/directories below opt-inputs/ are allowed.
        members = archive.getmembers()
        for item in members:
            path = Path(item.name)
            if path.is_absolute() or '..' in path.parts or path.parts[0] != 'opt-inputs' or not (item.isfile() or item.isdir()):
                raise RuntimeError(f'unsafe archive entry: {item.name}')
        archive.extractall(ROOT, members=members, filter='data')
    cases = json.loads((target / 'cases.json').read_text())
    expected = {'deep-static', 'wide-static', 'leaf-static', 'tce-cha', 'virtual-cfg'}
    if len(cases) != 5 or {c['name'] for c in cases} != expected:
        raise RuntimeError('expected five frozen opt workloads')
    for case in cases:
        for key in ('input', 'callback'):
            path = Path(case['name']) / Path(case[key]).name
            if not (target / path).is_file():
                raise RuntimeError(f'missing input: {path}')
            case[key] = str(path)
    (target / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
    for name, expected in hashes.items():
        if hashlib.sha256((ROOT/name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'extracted input changed: {name}')
    print('Prepared five opt workloads; native fixtures already available.')

if __name__ == '__main__':
    main()
