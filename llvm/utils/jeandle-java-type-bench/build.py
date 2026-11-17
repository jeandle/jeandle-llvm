#!/usr/bin/env python3
"""Build one native replay against its own Jeandle llvm-config."""
import argparse
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parent

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--llvm-config', type=Path, required=True)
    p.add_argument('--cxx', default='c++')
    p.add_argument('--api', choices=('legacy', 'v2', 'new', 'reference'), required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    config = a.llvm_config.resolve()
    def flags(*args):
        return shlex.split(subprocess.check_output([str(config), *args], text=True))
    source = ROOT / 'native' / ('driver-new.cpp' if a.api == 'new' else 'driver.cpp')
    define = {'legacy': [], 'reference': ['-DBENCH_REFERENCE'],
              'v2': ['-DBENCH_USE_V2'], 'new': ['-DBENCH_USE_NEW']}[a.api]
    out = a.out.resolve()
    if out.exists():
        p.error('output already exists; choose a fresh binary path')
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [a.cxx, str(source), '-I' + str(ROOT/'native'), *define,
           *flags('--cxxflags'), '-O3', '-DNDEBUG',
           *flags('--ldflags', '--link-static', '--libs', 'analysis', 'asmparser', 'core', '--system-libs'),
           '-o', str(out)]
    out.with_suffix('.command.txt').write_text(shlex.join(cmd) + '\n')
    subprocess.run(cmd, check=True)

if __name__ == '__main__':
    main()
