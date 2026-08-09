# Agent Remote — First Setup untuk AI Agent

Gunakan file ini untuk memandu pengguna baru. Ikuti urutan. Satu tahap gagal: berhenti, jelaskan perbaikan, jangan pakai fallback tidak aman.

## Aturan Wajib

- Pengguna login Tailscale sendiri pada PC dan HP. Jangan minta password akun Tailscale.
- PC dan HP harus memakai akun/tailnet sama.
- Jangan membuka port `9120` ke internet publik.
- Jangan menampilkan, menyalin, atau menyimpan token server pada chat, screenshot, repository, atau log.
- Jangan memilih folder kerja pengguna. Minta pengguna memilih folder project sendiri.
- Jangan menghentikan task aktif tanpa konfirmasi pengguna.

## Paket yang Harus Ada di PC

```text
AgentRemoteSetup.exe
ServerStart.exe
ServerStop.exe
PetUsage.exe
AgentRemote-latest.apk
```

Kelima file harus satu folder saat setup pertama.

## Runbook First-run

### 1. Tailscale dulu

1. Minta pengguna membuka Tailscale pada PC dan HP.
2. Minta pengguna login memakai akun yang sama.
3. Minta pengguna memastikan kedua device online.
4. PC: jalankan `tailscale ip -4`.
5. Lanjut hanya jika hasil PC berbentuk `100.x.x.x`.

Jika Tailscale meminta login, `NoState`, atau PC/HP offline: berhenti di sini.

### 2. Validasi agent PC

PC: jalankan minimal satu command berikut:

```powershell
codex --version
claude --version
gemini --version
opencode --version
```

Minimal satu harus berhasil. Jika tidak, perbaiki instalasi atau `PATH` agent sebelum lanjut.

### 3. Jalankan setup PC

1. Pengguna membuka `AgentRemoteSetup.exe`.
2. Tekan **Tambahkan ke Desktop + Start Menu**.
3. Tekan **Start Server**.
4. Tunggu status **Server aktif**.
5. Jangan screenshot QR pairing.

Token dibuat acak lokal otomatis. Jalur QR menyimpan token ke Android Keystore; AI agent tidak perlu meminta token.

### 4. Install dan hubungkan HP

1. Pengguna install `AgentRemote-latest.apk`.
2. Buka aplikasi Agent Remote.
3. Buka **Pengaturan**.
4. Tekan **Scan QR Pairing**.
5. Izinkan kamera.
6. Scan QR pada `AgentRemoteSetup.exe` di PC.
7. Tunggu status PC terhubung.

### 5. Folder dan session pertama

1. Pengguna memilih folder project lewat folder picker.
2. Gunakan permission **Ask** atau **Workspace**.
3. Buat **Session baru**. Folder tanpa session harus menampilkan tombol **Session baru**.
4. Kirim smoke check:

```text
Tampilkan nama workspace dan agent yang tersedia. Jangan mengubah file.
```

## Handoff Sukses

Selesai hanya jika semua benar:

- PC dan HP online pada tailnet sama.
- Status aplikasi PC terhubung.
- Minimal satu agent terdeteksi.
- Folder project dipilih pengguna.
- Session baru berhasil dibuat.
- Task smoke check muncul pada panel Proses.
- Tidak ada token tampil atau tersimpan di chat/log.

## Recovery Cepat

- **QR tidak muncul:** pastikan server aktif dan gunakan APK terbaru.
- **`401 unauthorized`:** scan QR ulang dari `AgentRemoteSetup.exe`; jangan meminta token kecuali jalur manual diperlukan.
- **Agent tidak terdeteksi:** cek `where.exe codex` atau command agent lain, lalu restart server.
- **HP tidak terhubung:** cek Tailscale online pada kedua device dan jangan gunakan IP publik.

Panduan detail/manual: [AGENT_REMOTE_AUTO_SETUP.md](AGENT_REMOTE_AUTO_SETUP.md).
