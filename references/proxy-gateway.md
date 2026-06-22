# Fail-closed proxy gateway (Parallels + xray TPROXY)

A battle-tested way to force **all** traffic from a client (and the gateway itself) through one proxy
node, with no possible bypass and a kill switch. The client needs zero proxy config and cannot leak.

## Why a separate gateway instead of configuring the client

A proxy set *inside* the client (system proxy, TUN app) relies on the client cooperating — apps can ignore
it, UDP/DNS/IPv6 slip past, and if the proxy app dies the client may fall back to direct (leak). A gateway
the client is physically routed through removes every other exit: the enforcement is **topological**, not
trust-based. The client has one NIC, one route, and that route only speaks "proxy."

```
Windows VM (or any client)
   │  only NIC: isolated Host-Only LAN, gateway = the Linux box
   ▼
Linux gateway VM
   ├─ dnsmasq      : DHCP + DNS hand-out to the client
   ├─ nftables     : TPROXY-redirect LAN + own traffic to xray; forward policy DROP (kill switch)
   ├─ xray         : dokodemo-door TPROXY :12345  ->  VLESS/proxy node   (sockopt mark 255 = no loop)
   └─ policy route : fwmark 1 -> table 100 -> local dev lo  (deliver marked pkts to xray)
   │  WAN NIC (NAT/shared) — used ONLY to reach the proxy node
   ▼
Proxy node  ──►  Internet     (single exit IP = the node's IP)
```

## Network layout (example)

- Gateway WAN `enp0s5` = NAT/shared (e.g. `10.211.55.4`) — only carries the encrypted tunnel to the node.
- Gateway LAN `enp0s6` = isolated Host-Only (e.g. `10.37.129.3/24`) — the client's only network.
- Disable the hypervisor's own DHCP on the Host-Only net; dnsmasq on the gateway serves it instead.

## xray config (`/usr/local/etc/xray/config.json`)

- inbound: `dokodemo-door` on `0.0.0.0:12345`, `network: tcp,udp`, `followRedirect: true`,
  `streamSettings.sockopt.tproxy: "tproxy"`, sniffing on.
- outbounds: the proxy node (`tag: proxy`) **with `streamSettings.sockopt.mark = 255`** (so xray's own
  connection to the node is not re-captured — loop prevention), plus `direct` (freedom) and `block`.
- routing: private/reserved IPs -> `direct`; everything from `tproxy-in` -> `proxy`.

Importing a VLESS share link into the outbound (parse on the host, write into the guest — never paste
secrets on a command line): see the parser snippet at the bottom. REALITY share-link params map to
`realitySettings`: `pbk`→`publicKey`, `sid`→`shortId`, `sni`→`serverName`, `fp`→`fingerprint`,
`pqv`→`mldsa65Verify` (post-quantum). `flow=xtls-rprx-vision` goes on the user object.

## nftables (`/etc/nftables-xray.conf`)

```
#!/usr/sbin/nft -f
add table ip xray
delete table ip xray
table ip xray {
    set reserved {
        type ipv4_addr ; flags interval
        elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
                     172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
    }
    chain prerouting {                       # LAN clients + (looped) local traffic
        type filter hook prerouting priority mangle; policy accept;
        ip daddr @reserved return            # private/own-subnet -> direct (do NOT restrict by iif:
        meta l4proto tcp tproxy to :12345 meta mark set 1 accept   # local OUTPUT traffic re-enters
        meta l4proto udp tproxy to :12345 meta mark set 1 accept   # prerouting via lo and must match
    }
    chain output {                           # gateway's OWN traffic -> proxy too
        type route hook output priority mangle; policy accept;
        meta mark 255 return                 # xray's own outbound (sockopt mark) -> direct (loop guard)
        ip daddr @reserved return
        ip daddr <NODE_IP> return            # traffic to the proxy node itself -> direct (loop guard)
        meta l4proto tcp meta mark set 1
        meta l4proto udp meta mark set 1
    }
    chain forward {                          # KILL SWITCH: nothing is forwarded directly
        type filter hook forward priority filter; policy drop;
    }
}
```

Key subtlety that costs hours if missed: the prerouting chain must **not** filter by input interface.
Locally-generated packets that the `output` chain marks get rerouted to `lo` and **re-enter prerouting**
with `iif = lo`; an `iifname != "enp0s6" return` would skip them and the gateway's own traffic would never
reach xray. Gate on `ip daddr @reserved` instead.

## Policy routing + sysctls (run at boot)

```bash
sysctl -w net.ipv4.conf.all.rp_filter=0      # loose rp_filter, or transparent replies get dropped
sysctl -w net.ipv4.conf.enp0s5.rp_filter=0
sysctl -w net.ipv4.conf.enp0s6.rp_filter=0
ip rule del fwmark 1 lookup 100 2>/dev/null; ip rule add fwmark 1 lookup 100
ip route flush table 100 2>/dev/null; ip route add local 0.0.0.0/0 dev lo table 100
nft -f /etc/nftables-xray.conf
```

TPROXY for local delivery does **not** need `ip_forward=1` (marked packets are delivered locally, not
forwarded). Leaving `ip_forward=0` plus the `forward drop` chain makes the kill switch doubly closed.

## Persistence

Put the routing+sysctl+nft block in `/usr/local/sbin/xray-tproxy.sh` and a oneshot unit
`/etc/systemd/system/xray-tproxy.service` (`After=network-online.target xray.service`,
`Wants=...xray.service` — *not* `Requires`, so the nft kill-switch stays loaded even if xray stops).
`systemctl enable --now xray-tproxy xray dnsmasq`.

## DHCP (`/etc/dnsmasq.d/vm-lan.conf`)

```
interface=enp0s6
bind-dynamic
port=0                                   # DHCP only, no local DNS
dhcp-authoritative
dhcp-range=10.37.129.100,10.37.129.200,255.255.255.0,12h
dhcp-option=option:router,10.37.129.3
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8   # client DNS goes to 1.1.1.1 -> TPROXY'd -> through node
```

## Cut the client over (last step, after the gateway verifies)

Switch the client's only NIC onto the isolated Host-Only net (on Parallels:
`prlctl set "<win-vm>" --device-set net0 --type host-only --iface "Host-Only"`). Reverse with
`--type shared`. Verify with `gateway_audit.sh --expect-ip <NODE_IP> --failclosed-test` and, from the
client, that its exit IP equals the node.

## Verification quick-reference

- Gateway's own `curl https://api.ipify.org` == node IP (because the `output` chain proxies it too).
- `gateway_audit.sh --failclosed-test`: stopping xray takes the gateway (and any client) fully offline;
  restarting restores it. No direct fallback = no leak.

## VLESS share-link → xray outbound (host-side parser)

```python
import json, urllib.parse as up
u = up.urlparse(URL); q = dict(up.parse_qsl(u.query))
reality = {"serverName": q.get("sni",""), "fingerprint": q.get("fp","chrome"),
           "publicKey": q.get("pbk",""), "shortId": q.get("sid",""), "spiderX": q.get("spx","")}
if q.get("pqv"): reality["mldsa65Verify"] = q["pqv"]      # post-quantum REALITY
proxy = {"tag":"proxy","protocol":"vless",
  "settings":{"vnext":[{"address":u.hostname,"port":u.port,
    "users":[{"id":u.username,"encryption":q.get("encryption","none"),"flow":q.get("flow","")}]}]},
  "streamSettings":{"network":q.get("type","tcp"),"security":q.get("security","reality"),
    "realitySettings":reality,"sockopt":{"mark":255}}}
```
