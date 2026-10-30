# ======================================================================
#  speedtest-rOSV6.rsc
#  Speedtest pakai server Ookla, murni script RouterOS (tanpa container)
#  Versi untuk RouterOS v6 (6.43 atau lebih baru).
#
#  Pasang  : Winbox/WebFig > System > Scripts > tombol +
#            Name: speedtest, paste seluruh isi file ini ke Source, OK
#  Jalankan: /system script run speedtest
#
#  Beda dengan versi v7:
#  - v6 tidak punya :timestamp dan :deserialize, jadi server WAJIB diisi
#    manual (serverHost) dan waktu diukur pakai /system clock (per detik)
#  - kecepatan diambil dari /interface monitor-traffic (rata-rata sampel)
#  - data upload maksimal 64 KB per request
# ======================================================================
{
# ------------------------------ PENGATURAN ----------------------------
# Interface WAN. Biarkan "" untuk deteksi otomatis dari default route.
:local wanIface ""
# Jumlah koneksi paralel saat download dan upload
:local streams 2
# Lama pengukuran per fase, dalam detik (angka saja)
:local testDur 10
# Pemanasan sebelum mulai dihitung (tidak masuk hasil)
:local warmup 2s
# Progress bar jalan di tempat (true). Set false kalau terminal
# menampilkan karakter aneh seperti [1A[2K
:local liveBar true
# Server Ookla (WAJIB di v6), format host:port
:local serverHost "jakarta2.speedtest.telkom.net.id:8080"
# Nama server untuk ditampilkan (opsional)
:local serverName "PT. Telekomunikasi Indonesia - Jakarta"
# URL legacy server (opsional, dipakai sebagai cadangan)
:local serverUrl "http://jakarta2.speedtest.telkom.net.id:8080/speedtest/upload.php"
# Ukuran file per request download (byte). Kecilkan kalau internet lambat.
:local chunkSize 10000000
# ----------------------------------------------------------------------

:global speedtestRun false
:global speedtestPayload ""
:local allJobs [:toarray ""]
:local errMsg ""
:local spinCh {"|";"/";"-";"\\"}

# Ubah nilai waktu jadi mikrodetik (angka polos dianggap milidetik)
:local toUs do={
  :local v $1
  :if ([:typeof $v] = "num") do={ :return ($v * 1000) }
  :if ([:typeof $v] = "str") do={ :set v [:totime $v] }
  :local s [:tostr $v]
  :local tot 0
  :local p [:find $s "d"]
  :if ([:typeof $p] = "num") do={
    :set tot ($tot + ([:tonum [:pick $s 0 $p]] * 86400000000))
    :set s [:pick $s ($p + 1) [:len $s]]
  }
  :local fr 0
  :if ([:len $s] > 9) do={
    :local f ([:pick $s 9 [:len $s]] . "000000")
    :set f [:pick $f 0 6]
    :while (([:len $f] > 1) && ([:pick $f 0 1] = "0")) do={ :set f [:pick $f 1 [:len $f]] }
    :set fr [:tonum $f]
  }
  :local parts [:toarray ""]
  :foreach i in={0;3;6} do={
    :local x [:pick $s $i ($i + 2)]
    :if ([:pick $x 0 1] = "0") do={ :set x [:pick $x 1 2] }
    :set parts ($parts, [:tonum $x])
  }
  :local hms (((($parts->0) * 3600) + (($parts->1) * 60)) + ($parts->2))
  :return (($tot + ($hms * 1000000)) + $fr)
}

# Jam sekarang dalam detik sejak tengah malam
:local nowSec do={
  :local t [:tostr [/system clock get time]]
  :local parts [:toarray ""]
  :foreach i in={0;3;6} do={
    :local x [:pick $t $i ($i + 2)]
    :if ([:pick $x 0 1] = "0") do={ :set x [:pick $x 1 2] }
    :set parts ($parts, [:tonum $x])
  }
  :return (((($parts->0) * 3600) + (($parts->1) * 60)) + ($parts->2))
}

# Tambah spasi di kiri sampai lebar $2
:local padL do={
  :local s [:tostr $1]
  :local w [:tonum $2]
  :while ([:len $s] < $w) do={ :set s (" " . $s) }
  :return $s
}

# Angka berskala jadi teks desimal. $2 = jumlah desimal (1 atau 2)
:local fmtDec do={
  :local v [:tonum $1]
  :local n [:tonum $2]
  :local div 10
  :if ($n = 2) do={ :set div 100 }
  :local f [:tostr ($v % $div)]
  :while ([:len $f] < $n) do={ :set f ("0" . $f) }
  :return (($v / $div) . "." . $f)
}

# Statistik latency (mikrodetik): avg, jitter, low, high
:local stats do={
  :local a $1
  :local n [:len $a]
  :local r [:toarray ""]
  :if ($n = 0) do={ :return $r }
  :local sum 0
  :local lo ($a->0)
  :local hi ($a->0)
  :local js 0
  :local prev -1
  :foreach v in=$a do={
    :set sum ($sum + $v)
    :if ($v < $lo) do={ :set lo $v }
    :if ($v > $hi) do={ :set hi $v }
    :if ($prev >= 0) do={
      :local d ($v - $prev)
      :if ($d < 0) do={ :set d (0 - $d) }
      :set js ($js + $d)
    }
    :set prev $v
  }
  :set ($r->"avg") ($sum / $n)
  :set ($r->"lo") $lo
  :set ($r->"hi") $hi
  :set ($r->"jit") 0
  :if ($n > 1) do={ :set ($r->"jit") ($js / ($n - 1)) }
  :return $r
}

# Format baris latency ala Ookla
:local latLine do={
  :local st $1
  :local out ""
  :foreach k in={"avg";"jit";"lo";"hi"} do={
    :local h ([:tonum ($st->$k)] / 10)
    :local f [:tostr ($h % 100)]
    :if ([:len $f] < 2) do={ :set f ("0" . $f) }
    :local t (($h / 100) . "." . $f)
    :if ($k = "avg") do={
      :while ([:len $t] < 9) do={ :set t (" " . $t) }
      :set out ($t . " ms   (jitter: ")
    }
    :if ($k = "jit") do={ :set out ($out . $t . "ms, low: ") }
    :if ($k = "lo") do={ :set out ($out . $t . "ms, high: ") }
    :if ($k = "hi") do={ :set out ($out . $t . "ms)") }
  }
  :return $out
}

# Counter byte interface. $2 = "down" (rx) atau "up" (tx)
:local cnt do={
  :if ($2 = "up") do={ :return [/interface get [find where name=$1] tx-byte] }
  :return [/interface get [find where name=$1] rx-byte]
}

:do {
  # Banner (warna cyan kalau liveBar aktif)
  :local cOn ""
  :local cOff ""
  :if ($liveBar) do={
    :set cOn "\1B[36;1m"
    :set cOff "\1B[0m"
  }
  :put ""
  :put ($cOn . "    ###  ####  ##### ##### ####  ##### #####  ###  #####")
  :put "   #     #   # #     #     #   #   #   #     #       #"
  :put "    ###  ####  ####  ####  #   #   #   ####   ###    #"
  :put "       # #     #     #     #   #   #   #         #   #"
  :put ("   ####  #     ##### ##### ####    #   ##### ####    #" . $cOff)
  :put ""
  :put "   Speedtest for MikroTik RouterOS v6 - using Ookla servers"
  :put ""

  # Progress bar jalan di tempat pakai kode ANSI di awal baris:
  # ESC[1A = kursor naik 1 baris, ESC[2K = hapus baris itu
  :local live $liveBar
  :local up "\1B[1A\1B[2K\r"
  :local pre ""

  # Ping dijalankan sebagai job background supaya output flood-ping
  # (sent/received/min-rtt...) tidak tercetak dan merusak progress bar.
  # Hasil RTT dikirim balik lewat variabel global speedtestRtt.
  :local pingFn do={
    :global speedtestRtt
    :set speedtestRtt ""
    :execute (":global speedtestRtt; /tool flood-ping address=" . $ip . " count=1 do={ :if (\$received > 0) do={ :set speedtestRtt \$\"avg-rtt\" } }")
    :local w 0
    :while (([:len [:tostr $speedtestRtt]] = 0) && ($w < 12)) do={
      :delay 100ms
      :set w ($w + 1)
    }
    :return $speedtestRtt
  }
  :local canPing true

  # Interface WAN (v6: dari gateway-status default route)
  :local wan $wanIface
  :if ($wan = "") do={
    :do {
      :local rid ([/ip route find where dst-address=0.0.0.0/0 active=yes]->0)
      :local gs [:tostr [/ip route get $rid gateway-status]]
      :local p [:find $gs "via "]
      :if ([:typeof $p] = "num") do={
        :set gs [:pick $gs ($p + 4) [:len $gs]]
      }
      :local sp [:find $gs " "]
      :if ([:typeof $sp] = "num") do={ :set gs [:pick $gs 0 $sp] }
      :local cm [:find $gs ","]
      :if ([:typeof $cm] = "num") do={ :set gs [:pick $gs 0 $cm] }
      :set wan $gs
    } on-error={}
  }
  :if ([:len [/interface find where name=$wan]] = 0) do={
    :set errMsg "Interface WAN tidak ketemu. Isi wanIface di bagian PENGATURAN, contoh: ether1"
    :error $errMsg
  }

  # ISP
  :local isp "-"
  :do {
    :local d ([/tool fetch url="http://ip-api.com/line/\?fields=isp" output=user as-value]->"data")
    :local nl [:find $d "\n"]
    :if ([:typeof $nl] = "num") do={ :set d [:pick $d 0 $nl] }
    :if ([:len $d] > 0) do={ :set isp $d }
  } on-error={}

  # Server (v6 tidak bisa membaca daftar server JSON dari speedtest.net)
  :if ($serverHost = "") do={
    :set errMsg "Versi v6 butuh server manual. Isi serverHost di bagian PENGATURAN, contoh: speedtest.contoh.net.id:8080"
    :error $errMsg
  }
  :local srvHost $serverHost
  :if ([:typeof [:find $srvHost ":"]] != "num") do={ :set srvHost ($srvHost . ":8080") }
  :local sponsor $serverName
  :if ($sponsor = "") do={ :set sponsor $srvHost }
  :local legacyUrl $serverUrl
  :if ($legacyUrl = "") do={ :set legacyUrl ("http://" . $srvHost . "/speedtest/upload.php") }

  :local srvIp ""
  :do {
    :set srvIp [:resolve [:pick $srvHost 0 [:find $srvHost ":"]]]
  } on-error={
    :set errMsg ("Gagal resolve " . $srvHost . ". Cek DNS router atau ganti serverHost.")
    :error $errMsg
  }
  :local pingOk false
  :if ($canPing) do={
    :local raw [$pingFn ip=$srvIp]
    :if ([:len [:tostr $raw]] > 0) do={ :set pingOk true }
  }

  :put ("      Server: " . $sponsor)
  :put ("         ISP: " . $isp)

  # Idle latency
  :local idle [:toarray ""]
  :local sentN 0
  :if ($pingOk) do={
    :while (($sentN < 10) && (([:len $idle] > 0) || ($sentN < 3))) do={
      :set sentN ($sentN + 1)
      :local raw [$pingFn ip=$srvIp]
      :if ([:len [:tostr $raw]] > 0) do={ :set idle ($idle, [$toUs $raw]) }
      :delay 100ms
    }
  }
  :local idleSt [$stats $idle]
  :if ([:len $idle] > 0) do={
    :put ("Idle Latency:" . [$latLine $idleSt])
  } else={
    :put "Idle Latency:      n/a   (server tidak membalas ping)"
  }

  # Siapkan URL download (cek dulu dengan file kecil)
  # "\\\?" menghasilkan "\?" supaya tanda tanya aman saat dipakai di job background
  :local dlSrc ""
  :do {
    :local r [/tool fetch url=("http://" . $srvHost . "/download\?size=100000") keep-result=no as-value]
    :set dlSrc ("http://" . $srvHost . "/download\\\?size=" . $chunkSize)
  } on-error={
    :do {
      :local base [:pick $legacyUrl 0 [:find $legacyUrl "upload.php"]]
      :local r [/tool fetch url=($base . "random350x350.jpg") keep-result=no as-value]
      :set dlSrc ($base . "random4000x4000.jpg")
    } on-error={}
  }

  # Siapkan URL dan data upload. Batas ukuran http-data di /tool fetch
  # beda-beda tiap router, jadi coba dari 64 KB turun sampai 1 KB.
  :local upSrc ""
  :local full "0123456789abcdef"
  :do {
    :for k from=1 to=12 do={ :set full ($full . $full) }
  } on-error={}
  :local upUrls [:toarray ""]
  :set upUrls ($upUrls, ("http://" . $srvHost . "/upload"))
  :set upUrls ($upUrls, $legacyUrl)
  :foreach sz in={65536;32768;16384;8192;4096;1024} do={
    :if (($upSrc = "") && ([:len $full] >= $sz)) do={
      :local d [:pick $full 0 $sz]
      :foreach u in=$upUrls do={
        :if ($upSrc = "") do={
          :do {
            :local r [/tool fetch url=$u http-method=post http-data=$d keep-result=no as-value]
            :set upSrc $u
            :set speedtestPayload $d
          } on-error={}
        }
      }
    }
  }
  :set full ""

  # Download lalu upload
  :local res [:toarray ""]
  :foreach ph in={"down";"up"} do={
    :local label "    Download"
    :local src $dlSrc
    :if ($ph = "up") do={
      :set label "      Upload"
      :set src $upSrc
    }
    :set ($res->$ph) -1
    :if ($src = "") do={
      :put ($label . ":      gagal (fetch ke server gagal)")
    } else={
      :local wSrc ""
      :if ($ph = "down") do={
        :set wSrc (":global speedtestRun; :local e 0; :local n 0; :while ((\$speedtestRun = true) && (\$e < 3) && (\$n < 500)) do={ :set n (\$n + 1); :do { /tool fetch url=\"" . $src . "\" keep-result=no } on-error={ :set e (\$e + 1); :delay 500ms } }")
      } else={
        :set wSrc (":global speedtestRun; :global speedtestPayload; :local e 0; :local n 0; :while ((\$speedtestRun = true) && (\$e < 3) && (\$n < 5000)) do={ :set n (\$n + 1); :do { /tool fetch url=\"" . $src . "\" http-method=post http-data=\$speedtestPayload keep-result=no } on-error={ :set e (\$e + 1); :delay 500ms } }")
      }

      # Jalankan beberapa koneksi paralel di background.
      # Job baru dicari dengan membandingkan daftar job sebelum dan sesudah.
      :local cStart [$cnt $wan $ph]
      :set speedtestRun true
      :local before [/system script job find]
      :for n from=1 to=$streams do={ :execute $wSrc }
      :delay 300ms
      :local jobs [:toarray ""]
      :foreach j in=[/system script job find] do={
        :if ([:typeof [:find $before $j]] != "num") do={ :set jobs ($jobs, $j) }
      }
      :set allJobs ($allJobs, $jobs)
      :if ($live) do={
        :put ($label . ":     0.00 Mbps [                    ]   0%")
      } else={
        :put ($label . ":   mengetes...")
      }
      :delay $warmup

      # Ukur selama testDur detik. Kecepatan = rata-rata sampel monitor-traffic.
      :local t0 [$nowSec]
      :local el 0
      :local sum 0
      :local nS 0
      :local spd 0
      :local spin 0
      :local ticks 0
      :local loaded [:toarray ""]
      :while (($el < $testDur) && ($ticks < ($testDur * 4))) do={
        :set ticks ($ticks + 1)
        :delay 500ms
        :local rxb 0
        :local txb 0
        /interface monitor-traffic interface=$wan once do={
          :set rxb $"rx-bits-per-second"
          :set txb $"tx-bits-per-second"
        }
        :local bps $rxb
        :if ($ph = "up") do={ :set bps $txb }
        # bit/s jadi Mbps x100
        :set sum ($sum + ([:tonum $bps] / 10000))
        :set nS ($nS + 1)
        :set spd ($sum / $nS)
        :local now [$nowSec]
        :if ($now < $t0) do={ :set now ($now + 86400) }
        :set el ($now - $t0)
        :local latTxt ""
        :if ($pingOk) do={
          :local raw [$pingFn ip=$srvIp]
          :if ([:len [:tostr $raw]] > 0) do={
            :local us [$toUs $raw]
            :set loaded ($loaded, $us)
            :set latTxt (" - latency: " . [$fmtDec ($us / 10) 2] . " ms")
          }
        }
        :if ($live) do={
          :local pct (($el * 100) / $testDur)
          :if ($pct > 100) do={ :set pct 100 }
          :local fill (($pct * 20) / 100)
          :local bar ""
          :for b from=1 to=20 do={
            :if ($b <= $fill) do={
              :set bar ($bar . "=")
            } else={
              :if ($b = ($fill + 1)) do={
                :set bar ($bar . ($spinCh->$spin))
              } else={
                :set bar ($bar . " ")
              }
            }
          }
          :set spin (($spin + 1) % 4)
          :put ($up . $label . ":" . [$padL [$fmtDec $spd 2] 9] . " Mbps [" . $bar . "] " . [$padL $pct 3] . "%" . $latTxt)
        }
      }

      # Hentikan koneksi background
      :set speedtestRun false
      :foreach j in=$jobs do={ :do { /system script job remove $j } on-error={} }
      :delay 1s

      # Hasil fase
      :local used ([$cnt $wan $ph] - $cStart)
      :if ($live) do={ :set pre $up }
      :if (($used < 100000) || ($nS = 0)) do={
        :put ($pre . $label . ":      gagal (tidak ada data yang lewat)")
      } else={
        :set ($res->$ph) $spd
        :put ($pre . $label . ":" . [$padL [$fmtDec $spd 2] 9] . " Mbps (data used: " . [$fmtDec ($used / 100000) 1] . " MB)")
        :if ([:len $loaded] > 0) do={
          :put ("             " . [$latLine [$stats $loaded]])
        }
      }
    }
  }

  # Packet loss (dari ping idle)
  :if ($sentN > 0) do={
    :local lossT ((($sentN - [:len $idle]) * 1000) / $sentN)
    :put (" Packet Loss:" . [$padL [$fmtDec $lossT 1] 9] . "%")
  }
  :put ""

  # Catat ke log juga (berguna kalau dijalankan dari scheduler)
  :local dTxt "gagal"
  :if (($res->"down") >= 0) do={ :set dTxt ([$fmtDec ($res->"down") 2] . " Mbps") }
  :local uTxt "gagal"
  :if (($res->"up") >= 0) do={ :set uTxt ([$fmtDec ($res->"up") 2] . " Mbps") }
  :local pTxt "n/a"
  :if ([:len $idle] > 0) do={ :set pTxt ([$fmtDec (($idleSt->"avg") / 10) 2] . " ms") }
  :log info ("speedtest: ping " . $pTxt . ", download " . $dTxt . ", upload " . $uTxt . ", server " . $sponsor)

} on-error={
  :if ($errMsg = "") do={ :set errMsg "Error tak terduga. Kirim pesan ini, nanti dicek bagian mana yang gagal." }
  :put ""
  :put ("ERROR: " . $errMsg)
  :put ""
}

# Bersih-bersih: hentikan job yang tersisa, hapus variabel global
:set speedtestRun false
:foreach j in=$allJobs do={ :do { /system script job remove $j } on-error={} }
:do { /system script environment remove [find where name="speedtestRun"] } on-error={}
:do { /system script environment remove [find where name="speedtestPayload"] } on-error={}
:do { /system script environment remove [find where name="speedtestRtt"] } on-error={}
}
