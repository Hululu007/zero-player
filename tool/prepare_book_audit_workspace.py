"""Restore immutable JSON inputs for historical audit scripts' recorded paths."""
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def prepare(root=ROOT):
    source = root / 'test_support' / 'book_source_audit'
    destination = root / 'docs' / 'implementation'
    files = sorted(source.glob('*.json'))
    if not files:
        raise FileNotFoundError(f'No audit fixtures in {source}')
    # Validate the entire destination before writing any missing input.
    for file in files:
        target = destination / file.name
        if target.is_symlink():
            raise ValueError(f'Refusing a linked audit input: {target}')
        if target.exists() and target.read_bytes() != file.read_bytes():
            raise ValueError(f'Existing audit input differs; preserved: {target}')
    destination.mkdir(parents=True, exist_ok=True)
    for file in files:
        target = destination / file.name
        if not target.exists():
            shutil.copyfile(file, target)
    return len(files)


if __name__ == '__main__':
    print(f'Prepared {prepare()} immutable local audit inputs; no network requests.')
