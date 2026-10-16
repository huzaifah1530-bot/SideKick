# Health Check integration — 16 October 2026

The user confirmed that the reported LocalDevVPN address workaround did not resolve `DeviceEndpointNotInitialized`, and requested a Health Check like SideStore's. Local Network permission is enabled. Sign-in succeeded with build 121, but device install/refresh remains unverified and unsuccessful in the latest evidence.

## Scope and implementation

Reuse SideStore's existing `HealthCheckView` and `HealthCheckViewModel` in the canonical patched iOS target. Navigation is available directly in SideKick Settings and under Connection & Pairing. The page shows the backend's readiness result, VPN/other interfaces, device reachability, pairing verification, active protocol, endpoint configuration and optional DDI status. An optional readiness title lets SideKick display “SideKick Ready” while existing upstream callers retain their default title.

Add the actual gateway service port to the same metrics snapshot and expose pull-to-refresh using the model's existing fetch/status/update path. There is no replacement health-check engine and no additional network or pairing configuration change. The new shipping patch is `patches/sidestore-health-check.patch`, applied after the existing integration/audit/authentication patches. Live interface/endpoint values stay in the page; the patch does not persist or automatically export them, and it does not expose credentials, pairing-file contents, account identifiers or device UDIDs.

## Investigation decisions

The latest device evidence identifies no selected reachable endpoint, rather than an absent VPN interface. Source review shows discovery chooses peers from routes/point-to-point metadata and TCP service-port probes. The candidate filter excludes tunnels with IPv6 addresses, and no automatically reachable candidate can leave the selected tunnel nil even when an explicit peer override exists. These are investigation leads. The screenshots do not establish which branch or port failed on this device, so this change adds visibility rather than an unverified discovery rewrite, arbitrary port override or startup delay.

The useful next device evidence is Health Check's Core Requirements, Connection Configuration (including the new Device Service Port and Active Protocol), and Available Local Interfaces after an attempted refresh. Do not request pairing files or account credentials. Confirm whether endpoint selection, TCP reachability or pairing verification fails before choosing the next fix.

## Verification

Local checks passed: 7 release-manifest/connection tests and 2 vendor patch-composition tests. The composition fixture applies the new patch in shipping order to an isolated clean vendor archive. Full Swift/product verification requires macOS Actions and will be recorded after the build. Opening and reading the Health Check page on device remains unverified. No successful refresh is claimed.

Graphify was consulted before source exploration and is refreshed after source edits. It describes the raw vendor checkout; inspect composed shipping patches for product behavior. Unrelated dirty VPN, vendor, audit and Graphify setup work is preserved, with no subagents used.
