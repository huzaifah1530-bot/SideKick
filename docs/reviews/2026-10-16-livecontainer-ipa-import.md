# Imported IPA handoff and GitHub source retention

The user requested Install in LiveContainer on the ready/imported IPA review,
including automatic retention of the GitHub source when the IPA was downloaded
through a pasted repository link. They clarified that this must not require
manually selecting/re-entering the repository after importing in LiveContainer.

AppManagementView now exposes the handoff for imported or queued IPAs, independent
of saved Apple IDs. The retained file is validated by IPAImportStore and handed
to the existing system activity view. LiveContainer performs the actual import;
SideKick does not write into its Applications directory or move native app data.
Linking LiveContainer's Applications folder remains a one-time access requirement.

Repository-picker downloads already persist GitHubImportChoice's configuration
on ImportedIPA: repository, release/Actions mode, workflow, branch, asset filter,
named token reference and the exact selected build key. The new path preserves
those fields. Update downloads now also freeze and retain the matching source
configuration before downloading, so queued updates can be handed off with the
same source information. Tokens themselves remain in the existing credential
store. Normal successful native installation continues using recordSuccessfulImport.

Before sharing a repository IPA, persist a handoff-intent flag on its existing
import record. This survives leaving the view or restarting SideKick. Catalogue
publication reconciles pending intents with accessible, non-snapshot guests whose
bundle/version/build match. A single unambiguous match gets its GitHub source
automatically; a different existing source is preserved. Multiple installations
or conflicting downloaded builds are not guessed. The UI allows explicit guest
selection for ambiguous installations, and ordinary file imports can configure
their GitHub source separately from guest details.

Sharing alone never advances the installed baseline. Discovery reads bounded
Mach-O load commands and retains the guest's LC_UUID; a matching downloaded
executable identity allows automatic recording of the selected build against the
guest's current observation. Missing or different binary evidence still saves the
repository configuration but leaves its installed baseline unknown. After source
persistence succeeds, clear the handoff intent using the exact original import
identity. This prevents an old handoff from resurrecting a deliberately forgotten
source. Failure to clear is retryable without changing an existing matching receipt.

Local Python integration checks pass. New Swift core tests exercise persisted
source/credential-reference retention, restart, explicit confirmation, automatic
association, idempotence, unknown binary evidence, source conflicts, snapshots,
ambiguous connections, and both scanner modes including executable-link rejection.
The Apple toolchain is unavailable locally; these tests and the full UI build
must run in macOS CI. No build polling or release publishing was performed.
