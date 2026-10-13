# GitHub update discovery and Updates navigation

Implement on main, preserving unrelated working changes. No subagents.

The user wants reliable discovery on launch, temporary build-history reuse, and an always-present Updates destination above Active in My Apps. Native and LiveContainer targets must share readable status rows and retain their respective installation flows.

1. Add a shared, in-memory GitHub history actor. Cache successful full history pages for five minutes by source, credential and page; coalesce simultaneous requests. Explicit checks reload the first page. Keep failures visible and never cache them as empty success. Retain source/observation publication guards.
2. Have checking and both version lists use the same pages. Publish a fresh history-derived check only against the currently saved source and target. Test older confirmed builds versus newer builds, unknown receipts, cache expiry, explicit reload, concurrent requests and credential/source partitioning.
3. Track scan completion time and configured sources in AppEnvironment. Request periodic checks while foregrounded, retain app-owned launch/foreground checks, and expose checking/unchecked/failed states rather than claiming no updates.
4. Add a native grouped Updates page: Available, Review Installed Build, Current, Skipped and Needs Attention. Show installed and latest build labels, last check time, refresh/retry, source settings and the existing native/LiveContainer install destinations. Add an always-visible summary navigation row above Active; move technical GitHub statuses off My Apps.
5. Reuse cached pages when opening version lists. Reload explicitly from pull-to-refresh or buttons; preserve old rows while reloading. Explain partial checks and unknown builds accurately.
6. Run portable Swift tests, integration checks, source parsing and the full iOS build. Review the final diff, push to main, and report on-device verification limits.
