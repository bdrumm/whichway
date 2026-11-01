"""A dual-stack host whose IPv6 is unreachable must not cost two connect timeouts per request."""
from __future__ import annotations

import socket

import urllib3.util.connection as conn

from mta_delay_insights import net


def _infos(v6, v4):
    return ([(socket.AF_INET6, socket.SOCK_STREAM, 6, "", (a, 443, 0, 0)) for a in v6]
            + [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (a, 443)) for a in v4])


def test_dead_ipv6_switches_the_process_to_ipv4_once(monkeypatch):
    monkeypatch.setattr(conn, "HAS_IPV6", True)
    monkeypatch.setattr(net, "_checked", {})
    tried = []

    def connect(addr, family, timeout):
        tried.append(addr[0])
        return family == socket.AF_INET

    resolve = lambda *a: _infos(["2606::1", "2606::2", "2606::3"], ["1.2.3.4"])  # noqa: E731
    assert net.prefer_ipv4_when_ipv6_is_dead("cdn.example", resolve=resolve, connect=connect) is True
    assert conn.HAS_IPV6 is False and tried == ["2606::1", "2606::2", "1.2.3.4"]
    assert net.prefer_ipv4_when_ipv6_is_dead("cdn.example", resolve=resolve, connect=connect) is True and len(tried) == 3


def test_working_or_absent_ipv6_leaves_urllib3_alone(monkeypatch):
    monkeypatch.setattr(conn, "HAS_IPV6", True)
    monkeypatch.setattr(net, "_checked", {})
    assert net.prefer_ipv4_when_ipv6_is_dead("ok.example", resolve=lambda *a: _infos(["2606::1"], ["1.2.3.4"]), connect=lambda *a: True) is False
    assert net.prefer_ipv4_when_ipv6_is_dead("v4.example", resolve=lambda *a: _infos([], ["1.2.3.4"]), connect=lambda *a: False) is False
    # IPv4 down as well: the network is the problem, not the address family
    assert net.prefer_ipv4_when_ipv6_is_dead("down.example", resolve=lambda *a: _infos(["2606::1"], ["1.2.3.4"]), connect=lambda *a: False) is False

    def gai(*a):
        raise socket.gaierror("no such host")

    assert net.prefer_ipv4_when_ipv6_is_dead("none.example", resolve=gai, connect=lambda *a: True) is None
    assert net.prefer_ipv4_when_ipv6_is_dead(None) is None
    assert conn.HAS_IPV6 is True and "none.example" not in net._checked
