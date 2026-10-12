# VA-005 supplemental verification

Scope: task ownership duplication in the six collection/table prefetching data sources in ArrayDataSource.swift, CompositeDataSource.swift and FetchedResultsDataSource.swift. Loader, cache, cell identity/index-path checks and completion behavior were preserved.

Added PrefetchTaskRegistry.swift, a pure Foundation owner shared by all six classes. It registers a generation before launching a Task, installs its handle only if that generation remains current, unregisters only the matching generation on completion, and removes/cancels the current handle on cancellation. NSLock protects background completion against UIKit cancellation. Old completion cannot remove a replacement, and late installation cannot resurrect canceled/completed work. Cancellation occurs outside the lock.

The three classes now hold registry instances; twelve task lifetimes delegate begin/install/finish and all cancellation sites delegate cancel. Their prior generation guard is retained centrally rather than repeated in six dictionary pairs.

Added Tests/PrefetchRegistry/PrefetchTaskRegistryRegression.swift. It runs real tasks with actor-controlled continuation gates: a loader ignoring cancellation completes after replacement; the replacement must remain registered and be reached by cancel. It also verifies installation after cancellation does not restore stale work. The fixture imports only Foundation and compiles against the actual production helper, not a copied model.

CI command from repository root:

```sh
swiftc -parse-as-library Vendor/SideStore/AltStore/Core/DataSources/PrefetchTaskRegistry.swift Tests/PrefetchRegistry/PrefetchTaskRegistryRegression.swift -o /tmp/sidekick-prefetch-regression
/tmp/sidekick-prefetch-regression
```

Windows verification: source migration counts checked (six owners/twelve task lifetimes), no old prefetchTaskIDs or direct dictionary removal remains, and vendor scoped git diff --check passes (line-ending notices only). Swift/swiftc are unavailable locally, so the Swift fixture has not executed and a semantic red/green test run is not claimed. Root will add fixture execution to macOS CI and include the new helper in vendor patch/build source registration. UIKit scrolling/prefetch behavior still requires Xcode/device validation.
