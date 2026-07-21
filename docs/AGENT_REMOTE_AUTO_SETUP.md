# Agent Remote — Auto Setup Pengguna Baru

> **Satu akun Tailscale. Dua device. Satu jalur aman ke agent PC.**
>
> Setup selalu dimulai dari membuat atau login akun Tailscale. Jangan menyalakan server sebelum PC dan HP berada pada tailnet yang sama.

**Tanggal dokumen:** 21 Juli 2026
**Paket:** Agent Remote `0.3.0+2`
**Target:** Windows 10/11 + Android 7+
**Status paket saat ini:** Release Candidate untuk pemakaian terbatas; baca [catatan release gate](#catatan-release-gate) sebelum distribusi publik.

---

## 1. Aturan untuk AI Setup Agent

AI agent yang menjalankan panduan ini wajib mengikuti urutan berikut:

1. **Minta pengguna membuat atau login akun Tailscale terlebih dahulu.** Login Tailscale harus dilakukan sendiri oleh pengguna melalui aplikasi/browser resmi.
2. Jangan meminta, menyimpan, atau mengirim password akun Tailscale.
3. Jangan memakai folder default milik developer; minta pengguna memilih folder kerja.
4. Jangan menulis token server ke repository, chat publik, screenshot, atau log task.
5. Buat token server acak sebelum server pertama kali dijalankan. Jangan gunakan `admin` untuk pemakaian rutin.
6. Jangan membuka port `9120` ke internet publik. Akses hanya melalui IP Tailscale atau LAN privat.
7. Tampilkan setiap tahap setup: `Tailscale → agent CLI → token → server → APK → koneksi → session pertama`.
8. Jika salah satu validasi gagal, berhenti pada tahap tersebut dan tampilkan perbaikan; jangan diam-diam memakai fallback yang lebih lemah.
9. Jangan menghentikan task agent yang sedang berjalan tanpa konfirmasi pengguna.
10. Setelah selesai, tampilkan endpoint, status Tailscale, agent yang terdeteksi, dan checklist verifikasi.

---

## 2. Siapkan Paket

Letakkan file berikut dalam satu folder pada PC Windows:

```text
AgentRemote-setup\
├─ ServerStart.exe
├─ ServerStop.exe
└─ AgentRemote-latest.apk
```

`ServerStart.exe` menjalankan gateway PC. `ServerStop.exe` menghentikan server beserta process agent yang dimulai oleh server. APK dipasang pada HP Android.

Jangan memindahkan atau mengganti nama `ServerStart.exe` dan `ServerStop.exe` secara terpisah. Keduanya harus berada pada folder yang sama.

---

## 3. Buat Akun Tailscale Dulu

### 3.1 Buat akun atau login

1. Pada PC, buka aplikasi Tailscale atau situs login resmi Tailscale.
2. Pilih **Sign up** jika belum punya akun.
3. Pilih provider login yang dipercaya pengguna.
4. Selesaikan login sampai perangkat PC muncul sebagai perangkat terdaftar.
5. Pada HP, install aplikasi Tailscale dari Play Store.
6. Login memakai akun Tailscale yang sama.
7. Izinkan permintaan VPN Android.
8. Pastikan PC dan HP terlihat pada tailnet yang sama dan statusnya online.

> **Catatan catchy:** Jangan pakai akun Tailscale berbeda antara PC dan HP. Jika akun berbeda, perangkat tidak otomatis bisa saling terhubung.

### 3.2 Validasi PC

Buka PowerShell baru pada PC:

```powershell
tailscale status
tailscale ip -4
```

Simpan IP `100.x.x.x` milik PC. Contoh:

```text
100.101.102.103
```

Jangan gunakan IP HP, IP publik router, atau IP contoh di atas. Jika command `tailscale` belum ditemukan, tutup PowerShell lalu buka kembali setelah Tailscale selesai di-install.

### 3.3 Syarat Tailscale sebelum lanjut

Semua kondisi ini harus terpenuhi:

- PC berstatus online.
- HP berstatus online.
- PC dan HP memakai tailnet yang sama.
- `tailscale ip -4` menghasilkan IP `100.x.x.x`.
- Tidak ada dua proses `tailscaled` yang berjalan bersamaan.
- Tailscale tidak sedang menampilkan `NoState`, `Logged out`, atau `Login required`.

Jika belum terpenuhi, **jangan lanjut ke ServerStart.exe**.

---

## 4. Siapkan Agent CLI di PC

Agent Remote tidak mengerjakan task di HP. Server meneruskan task ke CLI agent yang terpasang pada PC.

Install minimal satu agent CLI sesuai dokumentasi resminya, lalu validasi dari PowerShell:

```powershell
codex --version
claude --version
gemini --version
opencode --version
```

Command yang belum dipasang boleh gagal; minimal satu command harus berhasil.

Agent yang dapat dideteksi pada paket saat ini:

- Codex
- Claude Code
- Gemini CLI
- OpenCode
- Hermes, bila executable tersedia pada lokasi yang dikenali server

Jika agent terpasang tetapi tidak muncul:

```powershell
where.exe codex
where.exe claude
where.exe gemini
where.exe opencode
```

Jika hasil kosong, tambahkan lokasi executable ke `PATH` Windows, buka PowerShell baru, lalu jalankan validasi ulang.

---

## 5. Buat Token Server Aman

Jangan memakai token statis sederhana untuk pemakaian rutin. Jalankan PowerShell pada folder paket:

```powershell
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$rng.Dispose()
$token = [Convert]::ToHexString($bytes)
$env:AGENT_REMOTE_TOKEN = $token
[Environment]::SetEnvironmentVariable('AGENT_REMOTE_TOKEN', $token, 'User')
Set-Clipboard -Value $token
Write-Host "Token sudah dibuat dan disalin ke clipboard. Jangan bagikan token ini."
```

Token dipakai sebagai **Password** pada profile koneksi Agent Remote. Jangan commit token ke Git.

Jika token pernah terlihat orang lain:

```powershell
[Environment]::SetEnvironmentVariable('AGENT_REMOTE_TOKEN', $null, 'User')
```

Lalu buat token baru dan jalankan server dari process baru.

---

## 6. Jalankan Server Windows

Pada folder yang berisi `ServerStart.exe`:

```powershell
Start-Process .\ServerStart.exe -WindowStyle Hidden
```

Server akan:

- memakai port TCP `9120`;
- memakai workspace terakhir yang tersimpan, jika masih ada;
- mencoba mengaktifkan Tailscale yang sudah login;
- mendeteksi agent CLI pada `PATH`;
- menyimpan session di folder workspace pada `.agent-remote`;
- menulis log Tailscale lokal tanpa token task.

Validasi server dari PC:

```powershell
$ip = (tailscale ip -4).Trim()
$token = [Environment]::GetEnvironmentVariable('AGENT_REMOTE_TOKEN', 'User')
Test-NetConnection $ip -Port 9120
Invoke-RestMethod `
  -Uri "http://$ip`:9120/api/status" `
  -Headers @{ Authorization = "Bearer $token" }
```

Response `/api/status` harus mengandung `ok: true`.

### Firewall opsional

Jika Windows Firewall memblokir koneksi, buat rule khusus jaringan Tailscale melalui PowerShell **Administrator**:

```powershell
New-NetFirewallRule `
  -DisplayName "Agent Remote via Tailscale" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 9120 `
  -RemoteAddress 100.64.0.0/10 `
  -Action Allow `
  -Profile Any
```

Jangan membuat rule yang membuka port `9120` untuk `Any` tanpa pembatasan alamat.

---

## 7. Install APK di HP

1. Kirim `AgentRemote-latest.apk` ke HP.
2. Buka file APK pada HP.
3. Izinkan **Install unknown apps** hanya untuk aplikasi file manager/browser yang dipakai.
4. Install Agent Remote.
5. Buka aplikasi Tailscale dan pastikan VPN tetap aktif.
6. Buka Agent Remote setelah server PC aktif.

USB/ADB hanya diperlukan jika pengguna memilih instalasi melalui komputer. Pemakaian normal tidak memerlukan kabel USB.

---

## 8. Hubungkan Agent Remote ke PC

Pada Agent Remote:

1. Buka **Settings / Connection**.
2. Tambahkan profile **Gateway agent PC**.
3. Isi:

```text
Transport : custom
Endpoint  : http://100.101.102.103:9120
Username  : admin
Password  : token AGENT_REMOTE_TOKEN
```

Ganti endpoint dengan IP PC dari `tailscale ip -4`. Username hanya label profile pada versi ini; Password harus sama persis dengan `AGENT_REMOTE_TOKEN`.

4. Simpan profile.
5. Jadikan profile sebagai default.
6. Tekan **Connect**.
7. Tunggu status **PC aktif**.
8. Pilih folder kerja dari folder picker.
9. Buat **Session baru**.
10. Kirim pesan pendek untuk smoke check, misalnya:

```text
Tampilkan nama workspace dan agent yang tersedia. Jangan mengubah file.
```

### Koneksi berhasil jika

- status aplikasi menunjukkan PC aktif;
- folder PC dapat dipilih tanpa hardcode;
- daftar session muncul berdasarkan folder;
- agent yang terpasang terlihat;
- task smoke check masuk ke panel Process;
- `/api/status` merespons `ok: true`;
- tidak ada token atau password tampil pada UI/log publik.

---

## 9. Setup Folder, Permission, dan Session

Pilih folder project melalui folder picker. Jangan memberi izin `full` kecuali benar-benar diperlukan.

Rekomendasi:

- **Ask:** agent meminta approval sebelum operasi berisiko.
- **Workspace:** agent bekerja dalam workspace terpilih.
- **Full:** hanya untuk pengguna yang memahami risiko akses penuh.

Setiap folder menyimpan session sendiri. Saat pindah folder:

1. pilih folder baru;
2. tunggu workspace selesai dimuat;
3. buka session yang tersedia pada folder tersebut;
4. jangan menjalankan banyak refresh manual saat task aktif.

Session, task, dan file upload disimpan lokal pada workspace. Jangan memasukkan folder rahasia, folder password manager, atau root seluruh drive jika tidak diperlukan.

---

## 10. Operasi Harian

### Mulai kerja

```powershell
Start-Process .\ServerStart.exe -WindowStyle Hidden
```

Pastikan Tailscale online sebelum membuka Agent Remote.

### Hentikan kerja

Jangan menghentikan server saat task masih berjalan. Setelah task selesai:

```powershell
Start-Process .\ServerStop.exe
```

ServerStop menghentikan server dan process agent yang dibuat oleh server, lalu mencoba mematikan koneksi Tailscale sesuai konfigurasi launcher.

### LAN tanpa Tailscale

Hanya gunakan jika PC dan HP berada pada Wi-Fi privat yang sama:

```powershell
$env:AGENT_REMOTE_DISABLE_TAILSCALE = '1'
Start-Process .\ServerStart.exe -WindowStyle Hidden
```

Gunakan IP LAN PC dari `ipconfig`. Jangan memakai mode ini pada Wi-Fi publik atau guest network.

---

## 11. Troubleshooting Cepat

### Tailscale meminta login atau `NoState`

1. Tutup ServerStart.
2. Buka aplikasi Tailscale Windows.
3. Pastikan akun sudah login.
4. Jalankan `tailscale status`.
5. Pastikan hanya satu process `tailscaled` yang aktif.
6. Setelah status PC `online`, jalankan ServerStart lagi.

### HP tidak tersambung

Validasi berurutan:

```powershell
tailscale status
tailscale ip -4
Test-NetConnection <IP-TAILSCALE-PC> -Port 9120
```

Jika `TcpTestSucceeded` false, periksa server, Firewall, dan apakah HP masih online pada tailnet yang sama.

### `401 unauthorized`

Token pada profile HP berbeda dari token server. Ambil token dari environment user pada PC dan simpan ulang profile:

```powershell
[Environment]::GetEnvironmentVariable('AGENT_REMOTE_TOKEN', 'User')
```

Jangan mengirim token ke chat publik.

### Agent tidak muncul

```powershell
where.exe codex
where.exe claude
where.exe gemini
where.exe opencode
```

Install agent CLI atau perbaiki `PATH`, lalu restart ServerStart.

### Task terlihat thinking terus

- buka session yang benar;
- lihat panel **Process** lintas folder;
- pastikan server masih online;
- lakukan refresh satu kali setelah reconnect;
- jangan menjalankan dua ServerStart sekaligus.

### Server terasa berat

- gunakan mode **Hemat / Single agent**;
- hindari memilih semua agent sekaligus;
- jangan membuka banyak session dan folder secara bersamaan;
- jangan menjalankan fetch Git manual berulang;
- stop task yang tidak diperlukan melalui panel Process.

---

## 12. Batas Keamanan

- Agent Remote bukan layanan cloud publik.
- Jangan port-forward `9120` ke internet.
- Jangan membagikan akun Tailscale pribadi kepada pengguna lain.
- Untuk pengguna berbeda, setiap orang sebaiknya memakai tailnet dan perangkat miliknya sendiri.
- Token server adalah kredensial akses; perlakukan seperti password.
- HTTP cleartext hanya boleh dipakai di jaringan privat Tailscale/LAN yang dipercaya.
- Gunakan permission `ask` atau `workspace` untuk pengguna baru.
- Review folder workspace sebelum memberi izin agent menjalankan command.
- Jangan memasukkan secret, API key, atau file `.env` ke attachment tanpa alasan.

---

## 13. Checklist Handoff ke Pengguna Lain

- [ ] Pengguna membuat/login akun Tailscale.
- [ ] PC dan HP masuk tailnet yang sama.
- [ ] IP Tailscale PC sudah dicatat.
- [ ] Minimal satu CLI agent berhasil lewat PowerShell.
- [ ] Token `AGENT_REMOTE_TOKEN` dibuat acak.
- [ ] ServerStart dan ServerStop berada satu folder.
- [ ] Server `/api/status` mengembalikan `ok: true`.
- [ ] APK berhasil dipasang.
- [ ] Profile HP memakai endpoint dan token yang benar.
- [ ] Folder kerja dipilih manual.
- [ ] Session baru berhasil dibuat.
- [ ] Smoke check tidak mengubah file.
- [ ] Permission awal memakai `ask` atau `workspace`.

---

## 14. Catatan Release Gate

Audit lokal pada **21 Juli 2026** menunjukkan paket sudah layak sebagai **Release Candidate terbatas**, tetapi belum layak disebut public stable tanpa perbaikan berikut:

1. Ganti signing APK dari debug key ke release keystore milik produk.
2. Pastikan migrasi token acak first-run sudah dipakai pada seluruh paket distribusi.
3. Pastikan executable Hermes selalu dicari dari `PATH` atau `AGENT_REMOTE_HERMES_EXE`.
4. Sediakan installer/dependency check untuk pengguna Windows baru.
5. Uji pada Windows user baru dan Android device yang belum pernah memakai aplikasi.
6. Sediakan checksum dan kanal distribusi resmi untuk APK/EXE.
7. Pertimbangkan HTTPS/Tailscale Serve jika akses tidak dibatasi pada jaringan privat.
8. Jalankan backend test suite pada environment yang menyediakan `pytest`.

Jangan mengiklankan paket sebagai layanan internet terbuka sebelum release gate tersebut selesai.