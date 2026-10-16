# IPv4 interface recovery — 16 October 2026

## Device evidence and reproduced defect

Build 123's Health Check is working on device. The user supplied all requested sections after another failed refresh: Wi-Fi and utun presence are green, device reachability is red, pairing is loaded but unverified while disconnected, and the selected tunnel/peer are absent. The gateway uses remote pairing and service port 49152. Every interface reports no IPv4 address, including Wi-Fi and IPv4 loopback; only IPv6 entries survive. Local Network permission is enabled. Changing LocalDevVPN's tunnel subnet did not resolve the failure. These observations justify tracing the shared scanner rather than changing pairing, ports or addresses again.

`NetworkIfaceScanner.IPv4Info.init` requires both a host and a netmask. The shipping `minimuxer-audit-fixes.patch` made `sockaddrIPv4` require a complete `sockaddr_in`, then used it for netmasks too. Darwin legitimately trims trailing zero netmask bytes: a /8 mask can have length 5, /24 length 7, and /32 length 8 rather than the host structure's length 16. Rejecting these masks drops the entire IPv4 interface. This audit regression explains the blanket IPv4 loss; IPv6-only utun presence still produces a misleading green VPN indicator.

Apple's [XNU IPv4 implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/in.c) documents the actual behavior in `in_socktrim` and calls it from `in_ifinit`. The parser regression fixture reproduces the compact /8 failure against the shipping audit patch in [Actions build 124](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38904716283), with the explicit failure `REGRESSION: valid compact Darwin /8 mask dropped the IPv4 interface`. All 68 portable Swift tests passed in that run; the new regression intentionally blocked packaging.

## Targeted change and architecture

`patches/minimuxer-ipv4-netmask.patch` follows the audit patch in CI. Only interface netmask decoding changes: validate its family and declared length, then reuse the scanner's existing byte-bounded route-netmask decoder, which zero-fills omitted trailing bytes. Host/address validation remains strict. The patch does not weaken device TCP or pairing verification, change VPN configuration, replace endpoint discovery, or touch the dirty vendor checkout.

Data flow: Darwin `getifaddrs` → `IPv4Info` → `NetworkIfaceScanner.scan` → live `NetworkObserverService.activeInterfaces` and `DeviceConnectionManager` tunnel candidates → reachable peer selection → Minimuxer endpoint/readiness → install/refresh. Health Check reads the same scanner. A decoder defect therefore affects both the page and real connection discovery, rather than just display text.

## Verification and limits

The regression fixture compiles the actual parser and existing netmask helper from an isolated pinned vendor archive with shipping patches applied. It covers compact /8, /24, /32 and zero-length /0 masks; full masks; AF_INET/AF_UNSPEC mask families; invalid lengths/family; strict rejection of short or unspecified-family hosts; and live Darwin loopback IPv4. Windows checks patch composition but cannot execute Darwin Swift, so macOS CI is required for behavioral verification and the full product build.

Local checks passed: 7 release/connection fixtures and both authentication/vendor composition tests; the Darwin behavioral fixture is explicitly skipped on Windows. [Actions build 125](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38905203474) passed for `c7e12579c6185104123eaff84230e9a346879d49`: all 68 portable Swift tests, 7 release/connection tests, 3 shipping-patch tests (including the compiled Darwin fixture and live loopback), authentication recovery fixture, existing vendor regressions, and the full iOS build. The [standard IPA artifact](https://github.com/huzaifah1530-bot/SideKick/actions/runs/38905203474/artifacts/12048173110) was downloaded, its ZIP SHA-256 verified against GitHub's digest, and the IPA extracted to `C:\Users\Huzaifah\Downloads\SideKick-build-125.ipa`.

Device validation is pending: install build 125, retry refresh, and refresh Health Check to confirm IPv4 interfaces return and determine whether a reachable peer is selected. A successful macOS fixture/build does not prove that the user's VPN route and pairing will work after IPv4 discovery is restored. Do not clear pairing, rotate identities, or change ports speculatively if another stage fails. If IPv4 returns but discovery still fails, the existing IPv6 tunnel-candidate exclusion and service reachability remain separate investigation leads, not confirmed causes.

The user subsequently confirmed that build 125 worked. This establishes successful device validation for the reported connection/refresh failure; the next task concerns the separate LiveContainer transfer flow.

Graphify was consulted for scanner and test navigation and refreshed after edits. It describes the raw dirty vendor sources, not composed shipping patches. Unrelated VPN, vendor, audit and Graphify setup work remains intact; no subagents were used.
