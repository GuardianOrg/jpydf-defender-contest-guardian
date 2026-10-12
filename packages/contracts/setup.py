#!/usr/bin/env python3
"""Install public dependencies at the revisions recorded in foundry.lock."""
import concurrent.futures
import json
import pathlib
import subprocess

PACKAGE = pathlib.Path(__file__).resolve().parent
PINS = json.loads((PACKAGE / 'foundry.lock').read_text())
URLS = {
    'Solady': 'https://github.com/Vectorized/Solady.git',
    'V2-gov': 'https://github.com/liquity/V2-gov.git',
    'forge-std': 'https://github.com/foundry-rs/forge-std.git',
    'openzeppelin-contracts': 'https://github.com/OpenZeppelin/openzeppelin-contracts.git',
    'openzeppelin-contracts-upgradeable': 'https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git',
}

def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

def install(item):
    name, url = item
    dest = PACKAGE / 'lib' / name
    revision = PINS['lib/' + name]['rev']
    if not dest.exists():
        dest.mkdir(parents=True)
        run('git', 'init', str(dest))
        run('git', '-C', str(dest), 'remote', 'add', 'origin', url)
    current = subprocess.run(['git', '-C', str(dest), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    if current.returncode or current.stdout.strip() != revision:
        run('git', '-C', str(dest), 'fetch', '--depth', '1', 'origin', revision)
        run('git', '-C', str(dest), 'checkout', '--detach', revision)
    run('git', '-C', str(dest), 'submodule', 'update', '--init', '--recursive', '--depth', '1')
    actual = subprocess.check_output(['git', '-C', str(dest), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == revision, (name, actual, revision)
    print(f'{name}: {revision}', flush=True)

if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        list(pool.map(install, URLS.items()))
    print('Dependencies ready. Run forge build --root packages/contracts from the repository root.')
