# Changelog

## AgentRemote 0.5.0 ? 2026-08-08

- Rebrand produk, package Android, modul server, connector, spec, dan test menjadi `AgentRemote`.
- `ServerStart.exe` menyalakan `PetUsage.exe` setelah server siap; `ServerStop.exe` menghentikan satu process tree.
- Setup menyimpan toggle PET auto-start dan paket memasang `PetUsage.exe` bersama launcher lain.
- Chat menampilkan mode personalization efektif dan dapat mengulangi instruksi terakhir setelah task gagal.

## PetUsage 0.19.1 — 2026-08-08

- Active usage tidak lagi bergantung pada quota snapshot; Codex dan provider lain tetap tampil saat quota masih loading.
- Bar menampilkan model dan account aktif dari 9Router, termasuk aktivitas dari `providerConnections.lastUsedAt`.
- Bar menampilkan hingga delapan usage aktif tanpa menyembunyikan quota 0.

## PetUsage 0.19.0 — 2026-08-07

- Activity pulse memakai request 9Router terbaru; proses CLI tidak lagi menjadi sumber animasi palsu.
- Poll activity tidak lagi menunggu fetch quota network.
- Bar dibatasi delapan row dengan indikator overflow.
- Popup menghindari seluruh overlay pet, clamp multi-monitor, dan layout resize lebih responsif.
- Sprite sheet memakai delapan frame dan divalidasi saat startup.
- Build spec PetUsage memakai path relatif agar reproducible.

## PetUsage 0.18.0 — 2026-08-06

- Footer dipisah dari konten scroll; controls selalu terlihat dan tidak menimpa akun.
- Resize bebas lewat grip kanan-bawah, minimum `610×430`.
- Tombol memiliki state hover native Canvas.


## PetUsage 0.17.0 — 2026-08-06

- Bar usage memprioritaskan nama model aktif, bukan email akun.
- Dashboard 9Router kini tinggi/lebar tetap dan konten akun/quota memakai scrollbar.


## PetUsage 0.16.0 — 2026-08-06

- Menampilkan nama model aktif di bar monitoring atas pet.
- Mendukung multi-monitor: clamp dan roam memakai ruang koordinat virtual (`vrootx` / `vrootwidth`) sehingga pet bebas dipindahkan dan berkeliling ke monitor sekunder.


## PetUsage 0.15.0 — 2026-08-06

- Clamp jendela pet ke ukuran layar utama agar tidak hilang di monitor ganda.
- Layout segmented bar di atas pet disesuaikan mirip referensi LLMBar (kotak kecil memanjang).


## PetUsage 0.14.0 — 2026-08-06

- Status berpikir memakai proses CLI AI yang benar-benar hidup, bukan request `usageHistory` terakhir selama dua menit.


## PetUsage 0.13.0 — 2026-08-06

- Popup meringkas quota per akun. Klik akun untuk membuka/tutup model quota miliknya.
- Parser Antigravity menyamai daftar model quota 9Router; preview/internal model tidak lagi bocor ke popup.


## PetUsage 0.12.0 — 2026-08-06

- Popup quota memuat quota resmi Antigravity/Gemini langsung dari endpoint Google, termasuk agent yang sudah berhenti.


## PetUsage 0.11.0 — 2026-08-06

- Satu dispatcher Canvas menangani klik dan drag tanpa binding tombol yang saling menelan event.
- `SIZE <nilai>x` membuka input angka bebas 0.5–2.0; nilai disimpan sampai dua desimal.

## PetUsage 0.10.0 — 2026-08-06

- Root cause kontrol mati diperbaiki: binding `Canvas` menggantikan tag global yang menelan event tombol.
- Tombol BAR langsung render ulang state. Size dan filter tetap sinkron dengan state popup.

## PetUsage 0.9.0 — 2026-08-06

- Klik kiri Maha sekarang toggle popup: klik pertama buka, klik berikutnya sembunyikan.
- Drag handler panel ditempel ke tag Canvas `all`, sehingga drag tetap bekerja pada setiap teks, bar quota, dan area kosong.

## PetUsage 0.8.0 — 2026-08-06

- Popup kembali merender semua account/window dari quota tracker 9Router, termasuk provider dan status quota unavailable.
- Kontrol `SIZE -`, `SIZE +`, `SHARP`/`SMOOTH` tersimpan antar restart; range 0.5x–2x.
- Drag popup dipasang pada Canvas penuh, bukan hanya header.

## PetUsage 0.7.0 — 2026-08-06

- Bar atas hanya memuat akun dengan model yang benar-benar dipakai dalam 2 menit terakhir; quota `0%` tidak lagi dipanggil.
- Bar menjadi 20 segmen per akun; badge provider `CODEX`, `AG`, `GEMINI`, atau `OLLAMA` tampil sebelum nama akun.
- Alpha WebP pet dipotong pada threshold untuk menghapus halo chroma-key; popup dapat digeser dari area kosong mana pun.

## PetUsage 0.6.0 — 2026-08-06

- Bar atas Maha kini membuat satu progress bar per window quota dari setiap akun 9Router yang aktif.
- Popup menampilkan seluruh account tracker, termasuk quota unavailable; tinggi window bertambah sesuai jumlahnya.
- Header popup dapat didrag untuk memindahkan panel tanpa memicu kontrol lain.

## PetUsage 0.5.0 — 2026-08-06

- Toggle **BAR ON/OFF** sekarang mengatur bar usage ringkas di atas Maha dan tersimpan antar restart.
- Bar menampilkan provider, state idle/working, sisa quota resmi, dan klik untuk membuka detail.
- Sprite loop memakai accumulator 60 FPS dengan cadence Hermes Petdex 1100 ms / 6 frame; roaming tidak mengubah cadence.

## PetUsage 0.4.0 — 2026-08-06

- Usage window rebuilt as compact LLMBar-style edge monitor: flat dark surface, mono labels, real quota bars, no gradients/glow/cards.
- Maha v2 animation now follows Hermes Petdex contract: six frames, 1100 ms loop, nearest-neighbor pixels.
- Recent active 9Router request selects working animation; idle and directional roaming use matching atlas rows.
- Removed transparent-edge halo and blank idle frame that caused glow and blinking.

## PetUsage 0.3.0 — 2026-08-06

- UI panel dirombak menjadi dashboard card dark dengan hierarchy usage, mode pet, dan kontrol jelas.
- Maha v2 sekarang animasi idle atau running dari sprite sheet asli.
- Toggle **IDLE** dan **KELILING DESKTOP** tersimpan antar restart.
- Mutex Windows mencegah lebih dari satu pet instance.

## PetUsage 0.1.0 — 2026-08-06

- EXE pet always-on-top untuk usage lokal 9Router.
- Klik pet membuka request, token, biaya, model, dan quota resmi yang tersedia.
