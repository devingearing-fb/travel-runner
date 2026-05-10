import Foundation

struct HttpProbe: Probe {
    let url: String

    func check() async -> Bool {
        guard let url = URL(string: url) else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse {
                return (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
}
