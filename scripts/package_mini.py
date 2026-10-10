#!/usr/bin/env python3
"""Package code and frozen apps, excluding notification data and machine state."""
import hashlib
import json
import pathlib
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
destination = root/'deployment/NotificationLab-Mini-0.2.0.zip'
destination.parent.mkdir(exist_ok=True)
include = ['README.md', 'VALIDATION.md', 'docs', 'Sources', 'Tests', 'scripts', 'apps', 'NotificationLab.xcodeproj', 'validation/results.json', 'validation/unit-tests.txt']
files = []
for name in include:
    path = root/name
    files.extend([path] if path.is_file() else [p for p in path.rglob('*') if p.is_file() and '__pycache__' not in p.parts and not p.name.startswith('.')])
with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    directory = zipfile.ZipInfo('NotificationLab/')
    directory.external_attr = (0o40700 << 16) | 0x10
    archive.writestr(directory, b'')
    for path in sorted(files):
        archive.write(path, pathlib.PurePosixPath('NotificationLab')/path.relative_to(root))
metadata = {'package': destination.name, 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(), 'bytes': destination.stat().st_size, 'files': len(files), 'architecture': 'arm64', 'minimum_macos': '14.0', 'excluded': ['state', 'runs', 'generator', 'commands', 'health', 'live notification content', 'raw validation reports', 'machine-specific generated LaunchAgent']}
(destination.parent/'package.json').write_text(json.dumps(metadata, indent=2)+'\n')
print(json.dumps(metadata, indent=2))
