import Foundation

/// Runs CPU-heavy work (RSA generation, bcrypt key derivation) on a thread of its own and returns its result.
///
/// Synchronous tests run on Swift concurrency's shared pool, which has one thread per core. CI runs every test
/// in one process on a 3-core runner, and the key tests held the pool at the start of each run while async
/// tests elsewhere waited: in green runs for 4 to 7 s, and once, when RSA prime search took 20 s, for 12 s,
/// past the 10 s that ACP and terminal tests wait. Checks stay in the test, on its own task.
func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try work() }) }.start()
    }
}
