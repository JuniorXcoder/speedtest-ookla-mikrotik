# speedtest-quick-rOSV6.rsc
# Tes download cepat, 1 koneksi, untuk RouterOS v6.
# Bisa langsung di-paste ke terminal (Winbox New Terminal / SSH).
# v6 tidak punya :timestamp, jadi waktu diukur pakai jam router (per detik).
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
