# speedtest-quick-rOSV7.rsc
# Tes download cepat, 1 koneksi, untuk RouterOS v7.
# Bisa langsung di-paste ke terminal (Winbox New Terminal / SSH).
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
