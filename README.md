# limusic-bin-aur

Otomasi AUR untuk [`limusic-bin`](https://aur.archlinux.org/packages/limusic-bin), dibangun di atas GitHub Actions. Repo ini adalah **mirror + mesin** — isi AUR-nya sendiri (`PKGBUILD`, `.SRCINFO`) tetap dikirim ke `aur@aur.archlinux.org`.

Alur kerjanya menggantikan cron Hermes lama: cek rilis upstream, kalau tidak ada update langsung selesai tanpa mengubah apa pun, kalau ada update maka PKGBUILD + `.SRCINFO` diperbarui, dibangun, diperiksa `namcap`, baru kemudian dikirim ke AUR.

- Upstream: [SimoHypers/limusic](https://github.com/SimoHypers/limusic)
- Paket AUR: [limusic-bin](https://aur.archlinux.org/packages/limusic-bin)
- Repo ini: [xiryuudev/limusic-bin-aur](https://github.com/xiryuudev/limusic-bin-aur)

## Cara kerja

```
cron */5
  └─ check-update.sh            (runner biasa, ~10 detik)
       ├─ upstream /releases/latest  (hanya release stable)
       ├─ pkgver di PKGBUILD repo
       ├─ versi di AUR (AUR RPC)
       └─ tidak ada perubahan? → berhenti di sini
  └─ publish job (container archlinux:base-devel)
       ├─ ci-setup.sh           keyring, base-devel, namcap, user `builder`, deps runtime
       ├─ ci-build.sh
       │    ├─ render-pkgbuild.sh   unduh .deb, verifikasi sha256 vs digest GitHub,
       │    │                       tulis pkgver/pkgrel/sha256sums, regenerate .SRCINFO,
       │    │                       makepkg --verifysource
       │    └─ validate.sh          makepkg build, cek isi paket, .SRCINFO == printsrcinfo,
       │                            namcap PKGBUILD + paket (E: memblokir, W: dilaporkan)
       ├─ publish.sh            clone AUR, bandingkan, commit `upgpkg: limusic-bin <ver>`,
       │                        push, lalu verifikasi ulang isi remote
       └─ commit-state.sh       commit PKGBUILD/.SRCINFO hasil baru ke branch main
```

Kalau ada langkah yang gagal, job berhenti dan **tidak ada apa pun yang dikirim ke AUR**. Kegagalan dicatat sebagai satu issue GitHub (`limusic-bin automation failed`) supaya tidak hilang di riwayat run.

## Yang dideteksi

| Kondisi | Tindakan |
| --- | --- |
| Rilis stable baru (mis. `v1.3.0` → `v1.4.0`) | render, build, namcap, push AUR |
| Versi sama tapi upstream mengganti `.deb` (checksum berubah) | `pkgrel` dinaikkan, checksum diperbarui, push AUR |
| Repo sudah benar tapi AUR tertinggal satu versi | push ulang tanpa render |
| Tidak ada perubahan | berhenti setelah job `check` |
| AUR RPC sedang gangguan | run di-skip (tidak ada build 45 menit); `force=true` tetap bisa dipakai |
| Upstream menerbitkan tag rc/prerelease | diabaikan (hanya release stable) |

Kasus checksum berubah sengaja ditangani: dulu pernah upstream mengganti isi file untuk versi yang sama dan build gagal karena `sha256sums` usang.

## Sekali setup

### 1. Secret

Set di **Settings → Secrets and variables → Actions**:

| Nama | Isi |
| --- | --- |
| `AUR_SSH_PRIVATE_KEY` | private key SSH yang public key-nya terdaftar di akun AUR. Harus tanpa passphrase. |
| `AUR_USERNAME` | nama akun AUR (`xiryuu`) — wajib, dipakai sebagai author commit |
| `AUR_EMAIL` | email untuk commit AUR — wajib, harus sama dengan email akun AUR |

Ketiganya **wajib**: kalau `AUR_USERNAME` atau `AUR_EMAIL` kosong, workflow berhenti sebelum push (AUR mengaitkan commit ke akun lewat email, jadi author yang salah membuat paket tidak ter-update).

`GITHUB_TOKEN` sudah otomatis tersedia dan dipakai untuk commit state + issue; tidak perlu dibuat manual.

Kalau key belum ada, buat yang khusus untuk ini:

```bash
ssh-keygen -t ed25519 -C "aur-limusic-bin-ci" -f ~/.ssh/aur_limusic_ci -N ''
# tempel isi ~/.ssh/aur_limusic_ci.pub ke https://aur.archlinux.org/  (My Account → SSH Public Key)
cat ~/.ssh/aur_limusic_ci          # → isi seluruhnya ke secret AUR_SSH_PRIVATE_KEY
```

Private key boleh ditempel apa adanya (multi-baris) atau sebagai satu baris dengan `\n` — script menangani keduanya.

### 2. Aktifkan Actions

Di repo baru, Actions kadang perlu diaktifkan satu kali lewat tab **Actions**. Setelah itu jadwal `*/5 * * * *` langsung berlaku.

### 3. Uji tanpa menunggu jadwal

**Actions → limusic-bin AUR update → Run workflow**. Kalau upstream belum berubah, run akan selesai di job `check` dengan `update_needed=false` — itu memang perilaku yang benar.

Untuk memaksa pipeline penuh (build + namcap, dan push kalau ada perubahan):

```bash
gh workflow run update.yml -f force=true
```

`force` melewati keputusan "tidak ada update", tetapi **tetap** melewati semua gate: kalau build atau namcap gagal, AUR tidak disentuh. Kalau AUR ternyata sudah punya versi + checksum yang sama, push di-skip dan hanya commit state yang dijalankan.

## Frekuensi

GitHub membatasi jadwal minimum **5 menit**, dan **1 menit tidak didukung** cron GitHub.

Yang penting dan sering bikin bingung: penjadwal GitHub itu **best-effort**, bukan jam weker. Dokumentasi resminya menyebut run terjadwal *bisa tertunda* saat beban tinggi dan **bisa di-drop sepenuhnya tanpa notifikasi**. Beban paling padat tepat di awal jam, jadi cron yang menempel di `:00, :05, :10, ...` paling sering kena. Karena itu jadwal di repo ini digeser ke `2-59/5` (menit 2, 7, 12, ... 57) — tetap tiap 5 menit, tapi tidak berebut di jam sibuk.

Walau begitu, jadwal GitHub **tidak bisa diandalkan untuk ritme ketat**. Kalau kamu butuh kepastian, pemicu eksternal adalah satu-satunya cara: `scripts/trigger-workflow.sh` memanggil `workflow_dispatch` dan bisa dijalankan dari cron mana pun (cron-job.org, systemd timer, atau mesin yang sudah menyala).

```bash
# butuh token dengan izin "Actions: write" pada repo ini
GH_PAT=github_pat_xxx ./scripts/trigger-workflow.sh

# tiap 1 menit lewat crontab:
* * * * * GH_PAT=github_pat_xxx /path/ke/trigger-workflow.sh >/dev/null 2>&1
```

Dispatch hanya menyalakan job `check` yang murah (beberapa detik). Container Arch tetap hanya hidup kalau ada yang perlu dibangun, dan `concurrency` menahan run yang bertumpuk supaya tidak dobel.

Biaya: run tanpa update tidak memakai container sama sekali, jadi cek tiap 5 menit praktis gratis.

Karena jadwal GitHub juga dimatikan setelah 60 hari tanpa aktivitas repo, `keepalive.yml` menulis satu commit kecil tiap tanggal 1. Workflow itu memakai concurrency group yang sama dengan update, supaya tidak bertabrakan dengan push state.

## Menjalankan lokal

Butuh Arch Linux (atau turunannya) dengan `base-devel`, `namcap`, `jq`, `curl`.

```bash
./scripts/local-test.sh              # build + namcap untuk PKGBUILD saat ini
./scripts/local-test.sh 1.4.0        # pura-pura upstream merilis 1.4.0, lalu push AUR
DRY_RUN=true ./scripts/local-test.sh 1.4.0   # berhenti sebelum push AUR
./scripts/check-update.sh            # cek versi saja, tidak mengubah file
```

`local-test.sh <versi>` menulis ulang `PKGBUILD`/`.SRCINFO` di working tree, jadi jalankan di checkout yang bersih dan `git diff` setelahnya.

## Struktur

```
.github/workflows/update.yml    jadwal + pipeline build/validate/publish
.github/workflows/keepalive.yml heartbeat bulanan agar jadwal tidak dimatikan GitHub
scripts/check-update.sh         deteksi versi, checksum, dan resep yang tertinggal
scripts/render-pkgbuild.sh      unduh .deb + tulis PKGBUILD/.SRCINFO
scripts/validate.sh             build + namcap gate
scripts/publish.sh              commit & push ke AUR, lalu verifikasi
scripts/commit-state.sh         commit PKGBUILD baru ke branch main
scripts/ci-setup.sh             bootstrap container Arch
scripts/ci-build.sh             orkestrasi render + validate
scripts/as-builder.sh           jalankan sebagai user non-root (makepkg menolak root)
scripts/trigger-workflow.sh     pemicu manual/eksternal (workflow_dispatch)
scripts/aur-host-keys.txt       host key AUR yang di-pin
```

## Catatan

- `namcap` **E:** (error) memblokir push; **W:** (warning) hanya dicetak di log dan step summary.
- Host key `aur.archlinux.org` di-pin di `scripts/aur-host-keys.txt`; kalau AUR mengganti key, push akan gagal dan file itu perlu diperbarui.
- `keepalive.yml` menulis `.github/heartbeat` tiap tanggal 1 supaya GitHub tidak mematikan jadwal karena 60 hari tanpa aktivitas. Hapus file itu kalau tidak ingin ada commit bulanan.
- AUR tidak menerima file selain `PKGBUILD` dan `.SRCINFO`; `publish.sh` hanya mengirim dua file itu.
