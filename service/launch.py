"""Start without processing unrelated global .pth files or sitecustomize hooks.

Use: python -S launch.py [ros.server arguments]. Third-party dependencies remain
available from this interpreter's site-packages, but other editable projects do
not enter the app's import path.
"""
import sys, sysconfig, runpy
sys.dont_write_bytecode=True
from pathlib import Path
runtime=Path(sys.executable).parent.parent
if (runtime/'pyvenv.cfg').is_file():
    packages=runtime/'lib'/f'python{sys.version_info.major}.{sys.version_info.minor}'/'site-packages'
else:packages=Path(sysconfig.get_path('purelib'))
if packages.is_dir():sys.path.append(str(packages))
if '--diagnose' in sys.argv:
    import sqlite3,pymupdf,pymupdf4llm
    print('RESEARCHOS_RUNTIME_READY',sys.version.split()[0],flush=True)
elif '--organize' in sys.argv:
    sys.argv.remove('--organize');runpy.run_module('ros.organize',run_name='__main__')
else:runpy.run_module('ros.server',run_name='__main__')
