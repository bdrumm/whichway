"""Network hygiene shared by the fetchers.

urllib3 connects to a host's addresses in the order the resolver gives them, IPv6 first, and gives every attempt
the whole connect timeout. On a network that advertises IPv6 but routes it nowhere (this Mac's, 2026-10-31) each
request to a dual-stack host spent two full timeouts before the IPv4 fallback: a 1.4 MB archive day took 150 s
instead of 0.4 s. curl's happy eyeballs hides that; requests has none, so a fetcher gives each address a short
connect timeout (``CONNECT_SEC``) and, once a host's IPv6 proves dead, turns IPv6 off for the process.
"""
from __future__ import annotations

import logging
import socket
from typing import Callable

log = logging.getLogger(__name__)

CONNECT_SEC = 5.0  # per address attempt; a handshake takes well under a second
READ_SEC = 120.0
TIMEOUT = (CONNECT_SEC, READ_SEC)

_checked: dict[str, bool] = {}


def _try_connect(addr: tuple, family: int, timeout: float) -> bool:
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(addr)
        return True
    except OSError:
        return False
    finally:
        s.close()


def prefer_ipv4_when_ipv6_is_dead(host: str | None, port: int = 443, probe_sec: float = 3.0,
                                  resolve: Callable = socket.getaddrinfo, connect: Callable = _try_connect) -> bool | None:
    """Probe ``host`` once per process: when none of its IPv6 addresses accepts a connection within ``probe_sec``
    while an IPv4 one does, stop urllib3 from trying IPv6 from here on. True when it switched, False when IPv6
    works or the host has none, None when the host did not resolve (probed again next time)."""
    if not host:
        return None
    if host in _checked:
        return _checked[host]
    try:
        infos = resolve(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except OSError:
        return None
    v6 = [i[4] for i in infos if i[0] == socket.AF_INET6]
    v4 = [i[4] for i in infos if i[0] == socket.AF_INET]
    switched = False
    if v6 and v4 and not any(connect(a, socket.AF_INET6, probe_sec) for a in v6[:2]) and connect(v4[0], socket.AF_INET, probe_sec):
        import urllib3.util.connection as conn

        conn.HAS_IPV6 = False
        switched = True
        log.warning("%s: its IPv6 addresses do not answer from this network; IPv4 only for the rest of this process", host)
    _checked[host] = switched
    return switched
