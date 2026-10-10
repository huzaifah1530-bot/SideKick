# LocalDevVPN source

Based on https://github.com/seomin0610/LocalDevVPN at commit 8a97427bcbdf90cbb62c2eadb8cfe5751c50eccc.
PacketTunnelProvider.swift, CIDRValidator.swift and TunnelConstants.swift derive from that project. Original author and copyright headers are retained. LICENSE contains the complete StosVPN license.

SideKick adds a heartbeat watchdog, explicit packet-loop shutdown, and alignment-safe packet address swapping. It embeds this provider in a dedicated extension target. SideKick supplies its own UI and operation-scoped connection manager. The tunnel only routes the local 10.7.0.1 peer; it does not route internet traffic or use a remote VPN server.
