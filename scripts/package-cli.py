"""Package and smoke-test the native release executable."""
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import zipfile

system, arch, extension = (os.environ[name] for name in ('RELEASE_PLATFORM', 'RELEASE_ARCH', 'RELEASE_EXTENSION'))
expected_system = {'Linux': 'Linux', 'Darwin': 'Darwin', 'Windows': 'Windows'}[system]
assert platform.system() == expected_system
actual_arch = platform.machine().lower()
assert actual_arch in ({'x86_64', 'amd64'} if arch == 'x86_64' else {'arm64', 'aarch64'}), actual_arch
assert extension == ('zip' if system == 'Windows' else 'tar.gz')
executable = 'gdobs.exe' if system == 'Windows' else 'gdobs'
binary = Path('cli/target')/os.environ['RUST_TARGET']/'release'/executable
identity = f"gdobs {os.environ['VERSION']} ({os.environ['COMMIT']}, {os.environ['DATE']})"
assert subprocess.check_output([str(binary), 'version'], text=True).strip() == identity
Path('dist').mkdir(exist_ok=True)
archive = Path('dist')/f'gdobs_{system}_{arch}.{extension}'
if extension == 'zip':
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as bundle:
        bundle.write(binary, executable)
        bundle.write('README.md', 'README.md')
else:
    with tarfile.open(archive, 'w:gz') as bundle:
        bundle.add(binary, arcname=executable)
        bundle.add('README.md', arcname='README.md')

if system == 'Linux':
    assert os.environ['RUST_TARGET'].endswith('-linux-musl')
    assert 'INTERP' not in subprocess.check_output(['readelf','-l',str(binary)],text=True)
    assert '(NEEDED)' not in subprocess.check_output(['readelf','-d',str(binary)],text=True)
