# ======================================================================
#  speedtest.rsc
#  Speedtest pakai server Ookla, murni script RouterOS (tanpa container)
#  Butuh RouterOS v7.13 atau lebih baru.
#
#  Pasang  : Winbox/WebFig > System > Scripts > tombol +
#            Name: speedtest, paste seluruh isi file ini ke Source, OK
#  Jalankan: /system script run speedtest
#
#  Cara kerja singkat:
#  - ambil daftar server terdekat dari speedtest.net, pilih ping terendah
#  - latency diukur pakai ICMP (flood-ping)
#  - download/upload pakai beberapa /tool fetch paralel di background,
#    kecepatan dihitung dari counter byte interface WAN
# ======================================================================
{
# ------------------------------ PENGATURAN ----------------------------
# Interface WAN. Biarkan "" untuk deteksi otomatis dari default route.
:local wanIface ""
# Jumlah koneksi paralel saat download dan upload
:local streams 4
# Lama pengukuran per fase
:local testDur 10s
# Pemanasan sebelum mulai dihitung (tidak masuk hasil)
:local warmup 2s
# Kata kunci server, contoh "Surabaya" (tanpa spasi). "" = otomatis
:local serverSearch ""
# Progress bar jalan di tempat (true). Set false kalau terminal
# menampilkan karakter aneh seperti [1A[2K
:local liveBar true
# Server manual, dipakai kalau speedtest.net menolak (error 403).
# Isi host:port server Ookla, contoh "speedtest.contoh.net.id:8080"
:local serverHost "jakarta2.speedtest.telkom.net.id:8080"
# Nama server untuk ditampilkan (opsional)
:local serverName "PT. Telekomunikasi Indonesia - Jakarta"
# Field "url" dari JSON server (opsional, dipakai sebagai cadangan)
:local serverUrl "http://jakarta2.speedtest.telkom.net.id:8080/speedtest/upload.php"
# ----------------------------------------------------------------------

:global speedtestRun false
:global speedtestPayload ""
:local ua "User-Agent: Mozilla/5.0"
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
  :local p [:find $s "w"]
  :if ([:typeof $p] = "num") do={
    :set tot ($tot + ([:tonum [:pick $s 0 $p]] * 604800000000))
    :set s [:pick $s ($p + 1) [:len $s]]
  }
  :set p [:find $s "d"]
  :if ([:typeof $p] = "num") do={
    :set tot ($tot + ([:tonum [:pick $s 0 $p]] * 86400000000))
    :set s [:pick $s ($p + 1) [:len $s]]
  }
  :local fr 0
  :if ([:len $s] > 9) do={
    :set fr [:tonum [:pick ([:pick $s 9 [:len $s]] . "000000") 0 6]]
  }
  :local hms ((([:tonum [:pick $s 0 2]] * 3600) + ([:tonum [:pick $s 3 5]] * 60)) + [:tonum [:pick $s 6 8]])
  :return (($tot + ($hms * 1000000)) + $fr)
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
  :put ""
  :put "   Speedtest (RouterOS script, server Ookla)"
  :put ""

  # Progress bar jalan di tempat pakai kode ANSI di awal baris:
  # ESC[1A = kursor naik 1 baris, ESC[2K = hapus baris itu
  :local live $liveBar
  :local up "\1B[1A\1B[2K\r"
  :local pre ""

  # Fungsi ping dibuat lewat :parse supaya beda versi RouterOS tetap aman
  :local pingFn
  :local canPing false
  :do {
    :set pingFn [:parse ":local r \"\"; /tool flood-ping address=\$ip count=1 do={ :if (\$received > 0) do={ :set r \$\"avg-rtt\" } }; :return \$r"]
    :set canPing true
  } on-error={
    :do {
      :set pingFn [:parse ":local r \"\"; :local x [/tool flood-ping address=\$ip count=1 as-value]; :if ((\$x->\"received\") > 0) do={ :set r (\$x->\"avg-rtt\") }; :return \$r"]
      :set canPing true
    } on-error={}
  }

  # Interface WAN
  :local wan $wanIface
  :if ($wan = "") do={
    :do {
      :local rid ([/ip route find dst-address=0.0.0.0/0 active=yes]->0)
      :local ig [:tostr [/ip route get $rid immediate-gw]]
      :local pc [:find $ig "%"]
      :if ([:typeof $pc] = "num") do={
        :set wan [:pick $ig ($pc + 1) [:len $ig]]
      } else={
        :set wan $ig
      }
    } on-error={}
  }
  :if ([:len [/interface find where name=$wan]] = 0) do={
    :set errMsg "Interface WAN tidak ketemu. Isi wanIface di bagian PENGATURAN, contoh: ether1"
    :error $errMsg
  }

  # ISP
  :local isp "-"
  :do {
    :local d ([/tool fetch url="https://www.speedtest.net/speedtest-config.php" output=user as-value http-header-field=$ua]->"data")
    :local p [:find $d "isp=\""]
    :if ([:typeof $p] = "num") do={
      :local rest [:pick $d ($p + 5) [:len $d]]
      :set isp [:pick $rest 0 [:find $rest "\""]]
    }
  } on-error={}
  :if (($isp = "-") || ($isp = "")) do={
    :do {
      :local d ([/tool fetch url="http://ip-api.com/line/\?fields=isp" output=user as-value]->"data")
      :local nl [:find $d "\n"]
      :if ([:typeof $nl] = "num") do={ :set d [:pick $d 0 $nl] }
      :if ([:len $d] > 0) do={ :set isp $d }
    } on-error={}
  }

  # Daftar server: manual (serverHost) atau dari speedtest.net
  :local list [:toarray ""]
  :if ($serverHost != "") do={
    :local nm $serverName
    :if ($nm = "") do={ :set nm $serverHost }
    :local su $serverUrl
    :if ($su = "") do={ :set su ("http://" . $serverHost . "/speedtest/upload.php") }
    :set list {{"host"=$serverHost; "sponsor"=$nm; "name"=""; "id"="manual"; "url"=$su}}
  } else={
    :local q "engine=js&limit=5&https_functional=true"
    :if ($serverSearch != "") do={ :set q ($q . "&search=" . $serverSearch) }
    :local hdr "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36,Accept: application/json, text/plain, */*,Accept-Language: en-US,en;q=0.9,Referer: https://www.speedtest.net/"
    :foreach u in={"https://www.speedtest.net/api/js/servers";"http://www.speedtest.net/api/js/servers";"https://www.speedtest.net/api/ios-servers"} do={
      :if ([:len $list] = 0) do={
        :do {
          :local d ([/tool fetch url=($u . "\?" . $q) output=user as-value http-header-field=$hdr]->"data")
          :local arr [:deserialize from=json value=$d]
          :if (([:typeof $arr] = "array") && ([:len $arr] > 0)) do={ :set list $arr }
        } on-error={}
      }
    }
  }
  :if ([:len $list] = 0) do={
    :set errMsg "speedtest.net menolak request dari router (403). Isi serverHost di bagian PENGATURAN dengan host server Ookla, contoh: speedtest.contoh.net.id:8080"
    :error $errMsg
  }

  # Pilih server dengan ping terendah
  :if ($live) do={ :put "   Memilih server..." }
  :local best -1
  :local firstOk -1
  :local bestRtt 0
  :local srvIp ""
  :foreach i,s in=$list do={
    :local h [:tostr ($s->"host")]
    :if ([:len $h] > 0) do={
      :if ($firstOk = -1) do={ :set firstOk $i }
      :local hn $h
      :local cp [:find $h ":"]
      :if ([:typeof $cp] = "num") do={ :set hn [:pick $h 0 $cp] }
      :if ($canPing) do={
        :do {
          :local ip [:resolve $hn]
          :local sum 0
          :local got 0
          :local tr 0
          :while ($tr < 2) do={
            :set tr ($tr + 1)
            :local raw [$pingFn ip=$ip]
            :if ([:len [:tostr $raw]] > 0) do={
              :set sum ($sum + [$toUs $raw])
              :set got ($got + 1)
            } else={
              :set tr 2
            }
          }
          :if ($got > 0) do={
            :local avg ($sum / $got)
            :if (($best = -1) || ($avg < $bestRtt)) do={
              :set best $i
              :set bestRtt $avg
              :set srvIp $ip
            }
          }
        } on-error={}
      }
    }
  }
  :if ($best = -1) do={ :set best $firstOk }
  :if ($best = -1) do={
    :set errMsg "Daftar server dari speedtest.net kosong atau formatnya berubah."
    :error $errMsg
  }
  :local srv ($list->$best)
  :local srvHost [:tostr ($srv->"host")]
  :if ([:typeof [:find $srvHost ":"]] != "num") do={ :set srvHost ($srvHost . ":8080") }
  :local legacyUrl [:tostr ($srv->"url")]
  :local sponsor [:tostr ($srv->"sponsor")]
  :local pingOk ([:len [:tostr $srvIp]] > 0)
  :if ($live) do={ :set pre $up }
  :local srvName [:tostr ($srv->"name")]
  :if ($srvName = "") do={
    :put ($pre . "      Server: " . $sponsor)
  } else={
    :put ($pre . "      Server: " . $sponsor . " - " . $srvName . " (id: " . [:tostr ($srv->"id")] . ")")
  }
  :set pre ""
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

  # Siapkan URL download (cek dulu, sekaligus perkirakan ukuran potongan)
  :local dlSrc ""
  :do {
    :local t0 [:timestamp]
    :local r [/tool fetch url=("http://" . $srvHost . "/download\?size=1000000") output=none as-value]
    :local dt [$toUs ([:timestamp] - $t0)]
    :if ($dt < 1000) do={ :set dt 1000 }
    :local chunk ((1000000000000 / $dt) * 3)
    :if ($chunk < 1000000) do={ :set chunk 1000000 }
    :if ($chunk > 25000000) do={ :set chunk 25000000 }
    :set dlSrc ("http://" . $srvHost . "/download\\\?size=" . $chunk)
  } on-error={
    :do {
      :local base [:pick $legacyUrl 0 [:find $legacyUrl "upload.php"]]
      :local r [/tool fetch url=($base . "random750x750.jpg") output=none as-value]
      :set dlSrc ($base . "random2500x2500.jpg")
    } on-error={}
  }

  # Siapkan URL dan data upload (coba 64 KB dulu, lalu yang lebih besar)
  :local upSrc ""
  :local full "0123456789abcdef"
  :do {
    :for k from=1 to=16 do={ :set full ($full . $full) }
  } on-error={}
  :local upTry ("http://" . $srvHost . "/upload")
  :do {
    :local r [/tool fetch url=$upTry http-method=post http-data=[:pick $full 0 65536] output=none as-value]
    :set upSrc $upTry
  } on-error={
    :do {
      :local r [/tool fetch url=$legacyUrl http-method=post http-data=[:pick $full 0 65536] output=none as-value]
      :set upSrc $legacyUrl
    } on-error={}
  }
  :if ($upSrc != "") do={
    :set speedtestPayload [:pick $full 0 65536]
    :foreach sz in={262144;1048576} do={
      :do {
        :local r [/tool fetch url=$upSrc http-method=post http-data=[:pick $full 0 $sz] output=none as-value]
        :set speedtestPayload [:pick $full 0 $sz]
      } on-error={}
    }
  }
  :set full ""

  # Download lalu upload
  :local res [:toarray ""]
  :local durUs [$toUs $testDur]
  :local maxRun ($warmup + $testDur + 20s)
  :foreach ph in={"down";"up"} do={
    :local label "    Download"
    :local src $dlSrc
    :if ($ph = "up") do={
      :set label "      Upload"
      :set src $upSrc
    }
    :set ($res->$ph) -1
    :if ($src = "") do={
      :put ($label . ":      gagal (server menolak request)")
    } else={
      :local wSrc ""
      :if ($ph = "down") do={
        :set wSrc (":global speedtestRun; :local e 0; :local tEnd ([:timestamp] + " . $maxRun . "); :while ((\$speedtestRun = true) && (\$e < 3) && ([:timestamp] < \$tEnd)) do={ :do { /tool fetch url=\"" . $src . "\" output=none } on-error={ :set e (\$e + 1); :delay 500ms } }")
      } else={
        :set wSrc (":global speedtestRun; :global speedtestPayload; :local e 0; :local tEnd ([:timestamp] + " . $maxRun . "); :while ((\$speedtestRun = true) && (\$e < 3) && ([:timestamp] < \$tEnd)) do={ :do { /tool fetch url=\"" . $src . "\" http-method=post http-data=\$speedtestPayload output=none } on-error={ :set e (\$e + 1); :delay 500ms } }")
      }

      # Jalankan beberapa koneksi paralel di background
      :local cStart [$cnt $wan $ph]
      :set speedtestRun true
      :local jobs [:toarray ""]
      :for n from=1 to=$streams do={
        :set jobs ($jobs, [:execute $wSrc])
      }
      :local tracked ([:len $jobs] = $streams)
      :set allJobs ($allJobs, $jobs)
      :if ($live) do={
        :put ($label . ":     0.00 Mbps [                    ]   0%")
      } else={
        :put ($label . ":   mengetes...")
      }
      :delay $warmup

      :local ticks 0
      :if ($tracked) do={
        :local aliveW 0
        :foreach j in=$jobs do={
          :if ([:len [/system script job find where .id=$j]] > 0) do={ :set aliveW ($aliveW + 1) }
        }
        :if ($aliveW = 0) do={ :set ticks 999 }
      }

      # Ukur selama testDur
      :local c0 [$cnt $wan $ph]
      :local t0 [:timestamp]
      :local elUs 0
      :local spd 0
      :local spin 0
      :local loaded [:toarray ""]
      :while (($elUs < $durUs) && ($ticks < 120)) do={
        :delay 500ms
        :set ticks ($ticks + 1)
        :local c [$cnt $wan $ph]
        :set elUs [$toUs ([:timestamp] - $t0)]
        :if ($elUs > 0) do={ :set spd ((($c - $c0) * 800) / $elUs) }
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
          :local pct (($elUs * 100) / $durUs)
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
      :if ($tracked) do={
        :local wEnd ([:timestamp] + 15s)
        :local aliveS 1
        :while (($aliveS > 0) && ([:timestamp] < $wEnd)) do={
          :set aliveS 0
          :foreach j in=$jobs do={
            :if ([:len [/system script job find where .id=$j]] > 0) do={ :set aliveS ($aliveS + 1) }
          }
          :if ($aliveS > 0) do={ :delay 300ms }
        }
        :foreach j in=$jobs do={ :do { /system script job remove $j } on-error={} }
      } else={
        :delay 3s
      }

      # Hasil fase
      :local used ([$cnt $wan $ph] - $cStart)
      :if ($live) do={ :set pre $up }
      :if ($used < 100000) do={
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
}
