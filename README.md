# speedtest-ookla-mikrotik

Speedtest ala Ookla yang jalan langsung di router MikroTik, murni pakai script RouterOS (tanpa container). Mengukur ping, jitter, download, upload, dan packet loss ke server Ookla, dengan tampilan mirip Ookla Speedtest CLI.

> **Status:** belum dites di router asli. Kalau ketemu error, buka issue dan sertakan output script + `/system resource print`.

## Pilih versi

| File | RouterOS | Keterangan |
|------|----------|------------|
| [`speedtest-rOSV7.rsc`](speedtest-rOSV7.rsc) | v7.13+ | Versi lengkap. Bisa pilih server otomatis dari speedtest.net, waktu diukur presisi mikrodetik pakai `:timestamp`. |
| [`speedtest-rOSV6.rsc`](speedtest-rOSV6.rsc) | v6.43+ | Untuk router yang masih v6. Server wajib diisi manual, lihat [Beda versi v6](#beda-versi-v6). |
| [`speedtest-quick-rOSV7.rsc`](speedtest-quick-rOSV7.rsc) | v7 | Tes download cepat, bisa langsung di-paste ke terminal. Lihat [Tes cepat](#tes-cepat-paste-langsung-ke-terminal). |
| [`speedtest-quick-rOSV6.rsc`](speedtest-quick-rOSV6.rsc) | v6 | Sama seperti di atas, untuk RouterOS v6. |

Cek versi router:

```
/system resource print
```

Kalau versi v7 memunculkan `bad command name timestamp`, berarti router masih v6 (atau v7 di bawah 7.13). Pakai versi v6, atau upgrade RouterOS.

## Kebutuhan

- RouterOS sesuai tabel di atas.
- Router punya akses internet dan DNS jalan.
- Policy script: `read`, `write`, `test`, `policy` (default saat bikin script baru sudah cukup).

## Cara pasang

1. Buka Winbox/WebFig, masuk ke **System → Scripts**, klik **+**.
2. Isi **Name** dengan `speedtest`.
3. Paste seluruh isi file sesuai versi RouterOS ke kolom **Source**, lalu klik **OK**.

> Jangan paste script ke **New Terminal**. Teks yang panjang di terminal bisa bikin Winbox ketendang.

## Cara pakai

```
/system script run speedtest
```

Contoh tampilan (ilustrasi, angkanya karangan):

```
   Speedtest (RouterOS script, server Ookla)

      Server: PT. Telekomunikasi Indonesia - Jakarta
         ISP: PT Telekomunikasi Indonesia
Idle Latency:     12.34 ms   (jitter: 0.85ms, low: 11.20ms, high: 14.10ms)
    Download:     95.42 Mbps (data used: 120.5 MB)
                  18.20 ms   (jitter: 2.10ms, low: 13.40ms, high: 25.70ms)
      Upload:     38.17 Mbps (data used: 48.3 MB)
                  20.05 ms   (jitter: 3.40ms, low: 14.00ms, high: 31.20ms)
 Packet Loss:       0.0%
```

Selama tes berjalan, progress bar dengan spinner diperbarui terus di terminal. Hasil akhirnya juga dicatat ke **Log** (`speedtest: ping ..., download ..., upload ...`).

### Tes cepat: paste langsung ke terminal

Cuma mau cek kecepatan download sekilas tanpa pasang script? Paste blok sesuai versi RouterOS langsung ke **New Terminal** atau SSH.

**RouterOS v7** ([`speedtest-quick-rOSV7.rsc`](speedtest-quick-rOSV7.rsc)):

```
{
:local host "jakarta2.speedtest.telkom.net.id:8080"
:local size 25000000
:put "Download test (25 MB)..."
:local t0 [:timestamp]
/tool fetch url=("http://" . $host . "/download\?size=" . $size) output=none
:local ms ([:tonsec ([:timestamp] - $t0)] / 1000000)
:if ($ms < 1) do={ :set ms 1 }
:local kbps (($size * 8) / $ms)
:local dec [:tostr (($kbps % 1000) / 10)]
:if ([:len $dec] < 2) do={ :set dec ("0" . $dec) }
:put ("Download: " . ($kbps / 1000) . "." . $dec . " Mbps (" . $ms . " ms)")
}
```

**RouterOS v6** ([`speedtest-quick-rOSV6.rsc`](speedtest-quick-rOSV6.rsc)):

```
{
:local host "jakarta2.speedtest.telkom.net.id:8080"
:local size 100000000
:local toSec do={ :local t [:tostr $1]; :return ((([:tonum [:pick $t 0 2]] * 3600) + ([:tonum [:pick $t 3 5]] * 60)) + [:tonum [:pick $t 6 8]]) }
:put ("Download test (" . ($size / 1000000) . " MB)...")
:local t0 [$toSec [/system clock get time]]
/tool fetch url=("http://" . $host . "/download\?size=" . $size) keep-result=no
:local s ([$toSec [/system clock get time]] - $t0)
:if ($s < 0) do={ :set s ($s + 86400) }
:if ($s < 1) do={ :set s 1 }
:local kbps (($size * 8) / ($s * 1000))
:local dec [:tostr (($kbps % 1000) / 10)]
:if ([:len $dec] < 2) do={ :set dec ("0" . $dec) }
:put ("Download: " . ($kbps / 1000) . "." . $dec . " Mbps (" . $s . " detik)")
}
```

Contoh hasil (v7):

```
Download test (25 MB)...
      status: finished
  downloaded: 24414KiB
       total: 24414KiB
    duration: 3s
Download: 66.66 Mbps (3000 ms)
```

Catatan:
- Hanya tes **download**, **1 koneksi**. Hasilnya biasanya lebih rendah dari script lengkap yang pakai beberapa koneksi paralel.
- Kecepatan dihitung dari ukuran file dibagi lama fetch, jadi trafik klien lain tidak ikut terhitung.
- Default `size`: 25 MB di v7, 100 MB di v6. Di link lambat bisa makan waktu lama, kecilkan `size`, misalnya `10000000` (10 MB).
- Versi v7 butuh `:timestamp` dan `:tonsec`. Kalau muncul `bad command name`, pakai versi v6.
- Versi v6 mengukur waktu pakai jam router, presisinya per detik. Karena itu `size`-nya dibuat lebih besar (100 MB) supaya hasilnya lebih akurat.

### Jalan otomatis (scheduler)

```
/system scheduler add name=speedtest-harian interval=1d start-time=03:00:00 on-event="/system script run speedtest"
```

Hasilnya bisa dilihat di `/log print where message~"speedtest"`.

## Pengaturan

Semua pengaturan ada di bagian `PENGATURAN` di awal script.

| Variabel       | Default v7 | Default v6 | Keterangan |
|----------------|------------|------------|------------|
| `wanIface`     | `""`       | `""`       | Interface WAN. Kosong = deteksi otomatis dari default route. Isi manual (mis. `ether1`, `pppoe-out1`) kalau deteksi gagal. |
| `streams`      | `4`        | `2`        | Jumlah koneksi `/tool fetch` paralel. |
| `testDur`      | `10s`      | `10`       | Lama pengukuran download dan upload. Di v6 ditulis dalam detik, angka saja. |
| `warmup`       | `2s`       | `2s`       | Pemanasan sebelum mulai dihitung. |
| `liveBar`      | `true`     | `true`     | Progress bar jalan di tempat (pakai kode ANSI). Set `false` kalau terminal menampilkan karakter aneh seperti `[1A[2K`. |
| `serverSearch` | `""`       | —          | (v7 saja) Kata kunci kota/server (tanpa spasi), dipakai kalau `serverHost` kosong. |
| `serverHost`   | `jakarta2.speedtest.telkom.net.id:8080` | sama | Server Ookla manual (`host:port`). Di v7 boleh dikosongkan untuk pilih otomatis, di v6 **wajib** diisi. |
| `serverName`   | `PT. Telekomunikasi Indonesia - Jakarta` | sama | Nama server untuk ditampilkan. |
| `serverUrl`    | `http://.../speedtest/upload.php` | sama | URL legacy server, dipakai sebagai cadangan. |
| `chunkSize`    | —          | `10000000` | (v6 saja) Ukuran file per request download, dalam byte. Kecilkan kalau internet lambat. |

### Cara cari `serverHost`

Perlu kalau versi v7 kena error 403 dari speedtest.net, atau kalau pakai versi v6 (wajib server manual).

1. Buka link ini di browser PC atau HP. Ganti `Surabaya` dengan kota kamu, tanpa spasi:

   ```
   https://www.speedtest.net/api/js/servers?engine=js&search=Surabaya
   ```

2. Akan muncul teks JSON. Cari bagian `"host":`, misalnya `"host":"speedtest.namaisp.net.id:8080"`, lalu salin nilainya ke script:

   ```
   :local serverHost "speedtest.namaisp.net.id:8080"
   :local serverName "Nama ISP - Surabaya"
   ```

   Nilai `"url"` dari server yang sama bisa disalin ke `serverUrl` sebagai cadangan.

3. Simpan perubahan: buka **System → Scripts**, dobel klik `speedtest`, ubah baris tadi di kolom **Source** (atau hapus seluruh isinya dan paste file yang sudah diedit), lalu klik **OK**. Supaya Winbox tidak ketendang, edit atau paste di jendela Scripts itu, jangan di New Terminal.

## Cara kerja

- **Server:** pakai `serverHost` kalau diisi. Di v7, kalau kosong, ambil daftar server dari API speedtest.net lalu pilih yang ping-nya paling rendah.
- **Latency:** ICMP lewat `/tool flood-ping`. Jitter dihitung dari rata-rata selisih antar sampel.
- **Download/Upload:** beberapa `/tool fetch` paralel dijalankan di background (`:execute`).
  - v7: kecepatan = selisih counter `rx-byte`/`tx-byte` interface WAN dibagi waktu (presisi mikrodetik).
  - v6: kecepatan = rata-rata sampel `rx/tx-bits-per-second` dari `/interface monitor-traffic`.
- **Packet loss:** dari ping idle (maksimal 10 paket).

## Beda versi v6

RouterOS v6 tidak punya `:timestamp` dan `:deserialize`, jadi versi v6 lebih sederhana:

- **Server wajib manual** (`serverHost`), karena daftar server JSON dari speedtest.net tidak bisa dibaca.
- **Lama tes diukur pakai jam router** (`/system clock`), presisinya per detik.
- **Ukuran download per request tetap** (`chunkSize`), tidak menyesuaikan kecepatan link.
- **Data upload maksimal 64 KB per request**, jadi hasil upload di link cepat bisa sedikit di bawah aslinya.
- **ISP** diambil dari ip-api.com.

## Catatan penting

- **Beban CPU.** Router sendiri yang download/upload data, jadi di router kecil (hAP lite, RB750, dll.) CPU bisa 100% dan hasilnya dibatasi kemampuan CPU, bukan kecepatan internet. Untuk meringankan, kurangi `streams` (mis. 2) dan `testDur` (mis. 6 detik).
- **Hasil dihitung dari trafik interface WAN.** Trafik lain dari klien yang lewat WAN selama tes ikut terhitung. Untuk hasil paling akurat, tes saat jaringan sepi.
- **Kuota.** Satu kali tes bisa memakai ratusan MB, tergantung kecepatan link.

## Troubleshooting

| Pesan | Penyebab & solusi |
|-------|-------------------|
| `speedtest.net menolak request dari router (403)` | speedtest.net memblokir request dari router. Isi `serverHost` dengan server Ookla manual, lihat [Cara cari `serverHost`](#cara-cari-serverhost). |
| `Interface WAN tidak ketemu` | Isi `wanIface` dengan nama interface WAN. |
| `bad command name timestamp` | Script v7 dijalankan di RouterOS v6 atau v7 di bawah 7.13. Pakai `speedtest-rOSV6.rsc`, atau upgrade ke v7.13+. |
| `Versi v6 butuh server manual` | Isi `serverHost` di script v6, lihat [Cara cari `serverHost`](#cara-cari-serverhost). |
| `Gagal resolve ...` | DNS router bermasalah atau nama server salah. Cek `/ip dns`, atau ganti `serverHost`. |
| `Idle Latency: n/a` | Server tidak membalas ping. Download/upload tetap diukur. |
| `gagal (server menolak request)` | Server tidak mendukung endpoint download/upload. Coba server lain. |
| Winbox ketendang saat tes | CPU router mentok. Kurangi `streams` dan `testDur`. |

## Alternatif

Kalau router mendukung container (RouterOS v7, arsitektur ARM/ARM64/x86), Ookla Speedtest CLI resmi bisa dijalankan di dalam container untuk hasil yang lebih akurat.
