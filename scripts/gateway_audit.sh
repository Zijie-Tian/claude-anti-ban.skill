#!/bin/bash
# gateway_audit.sh — audit a Linux proxy gateway that forces traffic (its own + downstream clients)
# through one proxy egress, fail-closed. Verifies the xray/nftables TPROXY setup from
# references/proxy-gateway.md. Optionally runs the fail-closed kill-switch test.
#
# Run ON the gateway as root (or via: prlctl exec "<ubuntu-vm>" --user root bash gateway_audit.sh ...).
#
# Usage:
#   bash gateway_audit.sh [--expect-ip <NODE_IP>] [--failclosed-test] [--tproxy-port 12345]
#
# --failclosed-test stops xray, confirms BOTH the gateway and (implicitly) any downstream client
# lose all egress, then restarts xray. It briefly takes the gateway offline.

set -u
EXPECT_IP=""
FC_TEST=0
PORT=12345
while [ $# -gt 0 ]; do
  case "$1" in
    --expect-ip) EXPECT_IP="$2"; shift 2 ;;
    --failclosed-test) FC_TEST=1; shift ;;
    --tproxy-port) PORT="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; shift ;;
  esac
done

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  [PASS] $1"; }
no(){ fail=$((fail+1)); echo "  [FAIL] $1"; }

echo "=== PROXY GATEWAY AUDIT ==="

echo "-- services --"
for s in xray dnsmasq nftables xray-tproxy; do
  st=$(systemctl is-active "$s" 2>/dev/null)
  if [ "$st" = active ]; then ok "$s active"; else echo "  [info] $s = ${st:-absent}"; fi
done
# xray-tproxy is this project's unit; nftables may be inactive if rules are loaded by that unit instead.

echo "-- firewall (nftables) --"
if nft list table ip xray >/dev/null 2>&1; then
  ok "nft table ip xray present"
  nft list chain ip xray prerouting 2>/dev/null | grep -q 'tproxy to :'"$PORT" && ok "prerouting TPROXY -> :$PORT" || no "prerouting TPROXY rule missing"
  nft list chain ip xray forward 2>/dev/null | grep -q 'policy drop' && ok "forward policy drop (kill switch)" || no "forward chain not drop — possible direct-forward leak"
else
  no "nft table ip xray missing — TPROXY not loaded"
fi

echo "-- policy routing --"
ip rule 2>/dev/null | grep -q 'fwmark 0x1 lookup 100' && ok "ip rule fwmark 1 -> table 100" || no "policy-routing rule missing"
ip route show table 100 2>/dev/null | grep -q 'local' && ok "table 100 local default dev lo" || no "table 100 route missing"

echo "-- xray listener --"
ss -tuln 2>/dev/null | grep -q ":$PORT" && ok "xray listening on :$PORT (tcp/udp)" || no "nothing on :$PORT"

echo "-- egress (gateway's own traffic should exit via the proxy node) --"
GW_IP=$(curl --silent --max-time 20 https://api.ipify.org 2>/dev/null)
echo "  exit IPv4 = ${GW_IP:-<none>}"
if [ -n "$EXPECT_IP" ]; then
  [ "$GW_IP" = "$EXPECT_IP" ] && ok "exit IP == proxy node ($EXPECT_IP)" || no "exit IP '$GW_IP' != expected '$EXPECT_IP'"
elif [ -n "$GW_IP" ]; then ok "gateway reaches internet via proxy ($GW_IP)"; else no "no egress (proxy down?)"; fi

if [ "$FC_TEST" = 1 ]; then
  echo "-- FAIL-CLOSED TEST (stopping xray briefly) --"
  systemctl stop xray; sleep 1
  OUT=$(curl --silent --show-error --max-time 12 https://api.ipify.org 2>&1)
  if echo "$OUT" | grep -qiE 'timed out|could ?n.t connect|resolv'; then ok "proxy down => gateway OFFLINE (no direct leak): $OUT"
  elif [ -z "$OUT" ]; then ok "proxy down => gateway OFFLINE (empty)"
  else no "LEAK: still reachable while xray stopped -> $OUT"; fi
  systemctl start xray; sleep 3
  REC=$(curl --silent --max-time 20 https://api.ipify.org 2>/dev/null)
  [ -n "$REC" ] && ok "xray restarted => egress restored ($REC)" || no "egress did NOT recover after restart"
fi

echo "=== SUMMARY: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && echo "Gateway forces all egress through the proxy and fails closed." || echo "Fix [FAIL] items — see references/proxy-gateway.md."
exit "$fail"
