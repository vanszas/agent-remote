# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

block_cipher = None

SPECPATH = Path(SPECPATH)
ROOT = SPECPATH.resolve()

datas = [
    (str(ROOT / "assets" / "pet"), "assets/pet"),
]

a = Analysis(
    [str(ROOT / "tools" / "pet_usage.py")],
    pathex=[str(ROOT / "tools")],
    binaries=[],
    datas=datas,
    hiddenimports=["agent_remote_server", "PIL", "PIL._tkinter_finder"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='PetUsage',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
