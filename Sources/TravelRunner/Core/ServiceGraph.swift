import Foundation

struct ServiceGraph: Sendable {
    let nodes: [String: ServiceDefinition]
    let sortedIDs: [String]

    enum GraphError: Error, CustomStringConvertible {
        case cycleDetected([String])
        case unknownDependency(service: String, dependency: String)

        var description: String {
            switch self {
            case .cycleDetected(let ids):
                "Dependency cycle detected involving: \(ids.joined(separator: " → "))"
            case .unknownDependency(let service, let dependency):
                "Service '\(service)' depends on unknown service '\(dependency)'"
            }
        }
    }

    init(services: [ServiceDefinition]) throws {
        var nodeMap: [String: ServiceDefinition] = [:]
        for service in services {
            nodeMap[service.id] = service
        }
        self.nodes = nodeMap

        for service in services {
            for dep in service.dependsOn {
                guard nodeMap[dep] != nil else {
                    throw GraphError.unknownDependency(service: service.id, dependency: dep)
                }
            }
        }

        self.sortedIDs = try Self.topologicalSort(services: services)
    }

    func startOrder() -> [[String]] {
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        for (id, _) in nodes {
            inDegree[id] = 0
            adjacency[id] = []
        }

        for (id, def) in nodes {
            for dep in def.dependsOn {
                adjacency[dep, default: []].append(id)
                inDegree[id, default: 0] += 1
            }
        }

        var levels: [[String]] = []
        var queue = inDegree.filter { $0.value == 0 }.map(\.key).sorted()

        while !queue.isEmpty {
            levels.append(queue)
            var nextQueue: [String] = []
            for node in queue {
                for neighbor in adjacency[node, default: []] {
                    inDegree[neighbor, default: 0] -= 1
                    if inDegree[neighbor] == 0 {
                        nextQueue.append(neighbor)
                    }
                }
            }
            queue = nextQueue.sorted()
        }

        return levels
    }

    func dependents(of serviceID: String) -> Set<String> {
        var result: Set<String> = []
        var queue = [serviceID]
        while let current = queue.popLast() {
            for (id, def) in nodes where def.dependsOn.contains(current) {
                if result.insert(id).inserted {
                    queue.append(id)
                }
            }
        }
        return result
    }

    private static func topologicalSort(services: [ServiceDefinition]) throws -> [String] {
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        for service in services {
            inDegree[service.id] = 0
            adjacency[service.id] = []
        }

        for service in services {
            for dep in service.dependsOn {
                adjacency[dep, default: []].append(service.id)
                inDegree[service.id, default: 0] += 1
            }
        }

        var queue = inDegree.filter { $0.value == 0 }.map(\.key).sorted()
        var sorted: [String] = []

        while let node = queue.first {
            queue.removeFirst()
            sorted.append(node)

            for neighbor in adjacency[node, default: []] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                    queue.sort()
                }
            }
        }

        if sorted.count != services.count {
            let remaining = Set(services.map(\.id)).subtracting(sorted)
            throw GraphError.cycleDetected(Array(remaining))
        }

        return sorted
    }
}
