# Agent Remote — First Setup untuk Pengguna Public

> **Buat akun Tailscale dulu. Hubungkan dua device. Baru jalankan agent.**

Panduan ini untuk pengguna baru yang menerima paket Agent Remote. Tidak perlu source code, Flutter, Python, atau USB setelah aplikasi terpasang.

## Yang Dibutuhkan

- PC Windows 10/11.
- HP Android 7+.
- Tailscale pada PC dan HP.
- Minimal satu CLI agent pada PC: Codex, Claude Code, Gemini CLI, OpenCode, atau agent lain yang didukung paket.
- File berikut dalam satu folder PC:

```text
ServerStart.exe
ServerStop.exe
AgentRemoteSetup.exe
AgentRemote-latest.apk
```

## 1. Buat Akun Tailscale Dulu

1. Install Tailscale pada PC.
2. Pilih **Log in** lalu buat akun atau login.
3. Install Tailscale pada HP.
4. Login memakai akun Tailscale yang sama.
5. Izinkan VPN Android.
6. Pastikan PC dan HP terlihat **online** pada tailnet yang sama.

> **Satu akun. Dua device. Satu jalur aman.**
>
> Jangan memakai akun Tailscale berbeda pada PC dan HP. Jangan membagikan password akun Tailscale kepada orang lain.

Pada PowerShell PC, cek alamat Tailscale:

```powershell
tailscale status
tailscale ip -4
```

Catat IP PC yang berbentuk `100.x.x.x`. Jangan memakai IP HP atau IP publik internet.

## 2. Siapkan Agent PC

Pastikan minimal satu agent bisa dipanggil dari PowerShell:

```powershell
codex --version
claude --version
gemini --version
opencode --version
```

Command yang belum terpasang boleh gagal. Minimal satu harus berhasil.

Jika agent sudah terpasang tetapi tidak terlihat di aplikasi:

```powershell
where.exe codex
where.exe claude
where.exe gemini
where.exe opencode
```

Jika hasil kosong, perbaiki `PATH` Windows lalu buka PowerShell baru.

## 3. Jalankan Setup PC

Double-click `AgentRemoteSetup.exe`. File ini harus satu folder dengan `ServerStart.exe` dan `ServerStop.exe`.

1. Tekan **Start Server**.
2. Tunggu status menjadi **Server aktif**.
3. Biarkan QR tetap terbuka.
4. Jangan screenshot atau membagikan QR; QR berisi token akses PC.

Menu **Change Password** menghentikan server, mengganti token, lalu menyalakan server kembali. Perubahan ditolak saat task masih aktif. Setelah password berubah, scan QR ulang pada HP.

### Cara manual

Buka folder paket, lalu double-click `ServerStart.exe`.

Atau jalankan tanpa jendela console:

```powershell
Start-Process .\ServerStart.exe -WindowStyle Hidden
```

Saat first run, server membuat token acak lokal pada:

```text
%LOCALAPPDATA%\AgentRemote\server-token.txt
```

Ambil token tersebut untuk profile Android:

```powershell
Get-Content "$env:LOCALAPPDATA\AgentRemote\server-token.txt"
```

Jangan membagikan token. Token ini adalah password gateway PC.

Cek port server:

```powershell
Test-NetConnection (tailscale ip -4) -Port 9120
```

Nilai `TcpTestSucceeded` harus `True`.

## 4. Install Agent Remote di HP

1. Buka `AgentRemote-latest.apk` pada HP.
2. Izinkan **Install unknown apps** untuk aplikasi pembuka file.
3. Install dan buka Agent Remote.
4. Pastikan VPN Tailscale masih aktif.

USB hanya diperlukan untuk instalasi melalui ADB. Pemakaian harian tidak memerlukan USB.

## 5. Hubungkan HP ke PC

### QR pairing

1. Buka **Pengaturan**.
2. Tekan **Scan QR Pairing**.
3. Izinkan kamera.
4. Scan QR pada `AgentRemoteSetup.exe`.
5. Profile, endpoint, dan token tersimpan otomatis; aplikasi langsung mencoba terhubung.

### Cara manual

Di Agent Remote:

1. Buka **Settings / Connection**.
2. Tambahkan **Gateway agent PC**.
3. Isi:

```text
Transport : custom
Endpoint  : http://IP-TAILSCALE-PC:9120
Username  : admin
Password  : isi token server
```

Contoh endpoint:

```text
http://100.101.102.103:9120
```

Ganti IP contoh dengan hasil `tailscale ip -4` milik PC. Password harus sama dengan isi `server-token.txt`.

4. Simpan profile.
5. Jadikan profile sebagai default.
6. Tekan **Connect**.

Jika berhasil, Home menampilkan **PC aktif**.

## 6. Buat Session Pertama

1. Pilih folder kerja lewat folder picker.
2. Jangan memilih seluruh drive jika tidak diperlukan.
3. Pilih permission **Ask** atau **Workspace**.
4. Buat **Session baru**.
5. Kirim smoke check tanpa mengubah file:

```text
Tampilkan nama workspace dan agent yang tersedia. Jangan mengubah file.
```

Koneksi berhasil jika:

- PC aktif terlihat.
- Folder PC dapat dipilih.
- Session muncul berdasarkan folder.
- Agent terdeteksi.
- Task terlihat pada panel Process.
- Agent membalas smoke check.

## Pemakaian Harian

Mulai server:

```powershell
Start-Process .\ServerStart.exe -WindowStyle Hidden
```

Hentikan server setelah semua task selesai:

```powershell
Start-Process .\ServerStop.exe
```

`ServerStop.exe` menghentikan server dan process agent yang dibuat oleh server. Jangan menghentikan server saat task masih berjalan.

## Troubleshooting

### HP tidak terhubung

```powershell
tailscale status
tailscale ip -4
Test-NetConnection <IP-TAILSCALE-PC> -Port 9120
```

Pastikan PC dan HP online pada tailnet yang sama, server aktif, dan port `9120` tidak diblokir Firewall.

### `401 unauthorized`

Password profile HP berbeda dari token server. Baca ulang:

```powershell
Get-Content "$env:LOCALAPPDATA\AgentRemote\server-token.txt"
```

Simpan ulang Password profile, lalu Connect kembali.

### Tailscale `NoState` atau meminta login

1. Tutup ServerStart.
2. Buka aplikasi Tailscale Windows.
3. Login kembali jika diminta.
4. Tunggu status PC online.
5. Jalankan ServerStart lagi.

### Agent tidak terlihat

Pastikan command agent berhasil dari PowerShell dan `where.exe` menemukan executable. Setelah memperbaiki `PATH`, restart ServerStart.

### Server terasa berat

Gunakan mode **Single / Hemat**, jangan memilih semua agent sekaligus, dan hentikan task yang tidak diperlukan melalui panel Process.

## Batas Aman

- Jangan port-forward port `9120` ke internet.
- Jangan memakai Wi-Fi publik atau guest network untuk mode LAN.
- Jangan membagikan token server.
- Jangan memasukkan API key atau file rahasia ke attachment.
- Gunakan permission **Ask** atau **Workspace** untuk penggunaan pertama.

Panduan teknis lengkap: [AGENT_REMOTE_AUTO_SETUP.md](AGENT_REMOTE_AUTO_SETUP.md).
