import Foundation

actor CompletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@main
struct PrefetchTaskRegistryRegression {
    static func main() async {
        let registry = PrefetchTaskRegistry<Int>()
        let oldGate = CompletionGate()
        let replacementGate = CompletionGate()
        let oldToken = registry.begin(at: 1)
        let oldTask = Task {
            await oldGate.wait() // Deliberately ignores cancellation, like an external loader.
            registry.finish(at: 1, token: oldToken)
        }
        registry.install(oldTask, at: 1, token: oldToken)
        let replacementToken = registry.begin(at: 1)
        let replacementTask = Task {
            await replacementGate.wait()
            registry.finish(at: 1, token: replacementToken)
        }
        registry.install(replacementTask, at: 1, token: replacementToken)
        await oldGate.release()
        await oldTask.value
        precondition(registry.contains(1), "An old completion erased its replacement task")
        precondition(!replacementTask.isCancelled, "Replacing a task canceled the replacement")
        registry.cancel(at: 1)
        precondition(replacementTask.isCancelled, "Cancel must reach the registered replacement")
        precondition(!registry.contains(1), "Cancel must unregister the replacement")
        await replacementGate.release()
        await replacementTask.value

        let staleToken = registry.begin(at: 2)
        registry.cancel(at: 2)
        let staleTask = Task {}
        registry.install(staleTask, at: 2, token: staleToken)
        precondition(staleTask.isCancelled, "A task installed after cancellation must be canceled")
        precondition(!registry.contains(2), "Late installation must not resurrect canceled work")
        print("PrefetchTaskRegistry replacement/cancellation regression passed")
    }
}
