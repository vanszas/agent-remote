# -*- mode: python ; coding: utf-8 -*-

a = Analysis(
    ['tools\\agent_remote_setup.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=['tailscale_control', 'qrcode', 'PIL.ImageTk', 'PIL._tkinter_finder'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='AgentRemoteSetup',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['assets/branding/agent_v_logo_concept.png'],
)
