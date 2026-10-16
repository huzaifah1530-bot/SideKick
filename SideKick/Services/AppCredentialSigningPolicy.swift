import Foundation

// Shared with the SideSign integration so profile validation has behavioral tests.
enum AppCredentialSigningPolicy {
    static func groups(source: [String], destination: String, team: String, permitted: [String]) -> [String]? {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              !source.isEmpty, source.count <= 64, !source.contains(destination),
              destination == team + ".com.kdt.livecontainer.shared" ||
                (1...127).contains(where: { destination == team + ".com.kdt.livecontainer.shared.\($0)" }) else { return nil }
        let requested = Array(Set(source + [destination])).sorted()
        guard requested.allSatisfy({ group in
            group.count <= 1024 && group.hasPrefix(team + ".") &&
                group.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil &&
                permitted.contains(where: { rule in
                    rule == group || (rule.hasSuffix(".*") && !rule.dropLast().contains("*") && group.hasPrefix(String(rule.dropLast())))
                })
        }) else { return nil }
        return requested
    }
}
