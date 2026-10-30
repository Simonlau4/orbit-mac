import Foundation
import OrbitCore
import Darwin

// No daemon, arbitrary shell, target paths or package execution. One authenticated transaction only.
do {
    let receipt = try await UpdateAuthorizationAgent.execute(arguments: Array(CommandLine.arguments.dropFirst()))
    let data = try JSONEncoder().encode(receipt)
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
