# limusic untuk Arch Linux

Paket AUR komunitas untuk [limusic](https://github.com/SimoHypers/limusic).

```sh
paru -S limusic-bin
# atau: yay -S limusic-bin
```

Jalankan **limusic** dari menu aplikasi atau ketik `limusic-app`.

Butuh driver audio yang berfungsi (libmpv) dan `webkit2gtk-4.1`. Login YouTube
Music memakai akunmu sendiri.

## Cara update-nya bekerja

Tidak ada yang di-push ke AUR kalau ada yang gagal.

```
watch.yml        cek rilis upstream tiap 1 menit, hidup ~6 jam lalu menyambung
  └─ update.yml  dipanggil begitu ada rilis baru
       ├─ check    bandingkan upstream vs PKGBUILD vs AUR (tanpa container)
       ├─ build    makepkg + namcap di container Arch; error memblokir
       └─ publish  push ke AUR, lalu verifikasi ulang isi remote
```

`watch.yml` yang membuat update cepat: jadwal cron GitHub sering telat berjam-jam
(dan di sebagian repo tidak pernah jalan), jadi watch melakukan polling sendiri
dan menyalakan `update.yml` dalam ~1 menit setelah rilis.

## Sekali setup

Set di **Settings → Secrets and variables → Actions**:

| Secret | Isi |
| --- | --- |
| `AUR_SSH_PRIVATE_KEY` | private key SSH yang terdaftar di akun AUR (tanpa passphrase) |
| `AUR_USERNAME` | nama akun AUR |
| `AUR_EMAIL` | email akun AUR — author commit harus cocok |

Ketiganya wajib. Kalau author tidak cocok dengan akun AUR, paket tidak ter-update
walau push-nya berhasil.

Key salah akan ditolak dengan pesan jelas. Fingerprint key yang dipakai
dicetak di log — cocokkan dengan yang ada di akun AUR.

## Menjalankan lokal

Butuh Arch (atau turunannya) dengan `base-devel`, `namcap`, `jq`.

```sh
./scripts/check-update.sh        # cek versi saja, tidak mengubah file
./scripts/local-test.sh          # build + namcap untuk PKGBUILD saat ini
./scripts/local-test.sh 1.4.0    # paksa versi 1.4.0 (menulis ulang PKGBUILD)
```

## Struktur

```
.github/workflows/watch.yml     polling rilis, menyalakan update.yml
.github/workflows/update.yml    check → build → validate → publish
scripts/watch.py                logika polling
scripts/check-update.sh         deteksi versi, checksum, dan resep tertinggal
scripts/render-pkgbuild.sh      unduh .deb, verifikasi sha256, tulis PKGBUILD/.SRCINFO
scripts/validate.sh             makepkg + namcap gate
scripts/publish.sh              push ke AUR, lalu verifikasi
scripts/commit-state.sh         commit PKGBUILD baru ke main
scripts/ci-setup.sh             bootstrap container Arch
scripts/ci-build.sh             orkestrasi render + validate
scripts/as-builder.sh           jalankan sebagai user non-root (makepkg menolak root)
scripts/aur-host-keys.txt       host key AUR yang di-pin
```

## Catatan

- `namcap` **E:** memblokir push; **W:** hanya dicetak di log.
- `pkgrel` dinaikkan saat upstream mengganti file untuk versi yang sama, supaya
  user benar-benar rebuild.
- Host key AUR di-pin; kalau AUR mengganti key, push gagal dan
  `scripts/aur-host-keys.txt` perlu diperbarui.
- `keepalive.yml` menulis `.github/heartbeat` tiap tanggal 1 supaya jadwal tidak
  dimatikan GitHub setelah 60 hari tanpa aktivitas.
