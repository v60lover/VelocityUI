// DimensionCache.swift

#if canImport(UIKit)
  import Foundation
  import CoreGraphics
  import ImageIO
  import os

  /// Thread-safe URL → CGSize store for dimension-first image fetching.
  ///
  /// DI contract: inject the **same** instance into `classify()` and `ImageActor`.
  /// ImageActor writes dimensions as a decode-time side effect via `store(_:for:)`;
  /// nonisolated `classify()` reads from the same store via `get(_:)`.
  /// Separate instances break the cache-hit contract.
  /// Pass the same URLSession to both via `init(session:)` so dimension probes and
  /// full-image fetches share one HTTP/2 connection pool — one TCP/TLS handshake per
  /// origin covers both.
  ///
  /// URL identity: query parameters are part of the key (e.g. `?v=1` vs `?v=2` cache
  /// separately). Intentional — CDN cache-busting params must not share entries.
  ///
  /// Eviction: unbounded dictionary. At ~116B/entry, 10k URLs ≈ 1.2MB. Flag for
  /// Phase 6 hardening (LRU eviction or NSCache-backed store).
  public final class DimensionCache: Sendable {

    // Single lock over both maps so cache re-check + inFlight read/write are atomic.
    private struct State {
      var cache: [URL: CGSize] = [:]
      var inFlight: [URL: Task<CGSize?, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let session: URLSession

    /// - Parameter session: URLSession to use for ranged probes. Inject a shared instance
    ///   so dimension probes and full-image fetches (ImageActor) reuse the same HTTP/2
    ///   connection pool and TLS session. Defaults to `.shared` for call-site convenience.
    public init(session: URLSession = .shared) {
      self.session = session
    }

    // MARK: - Sync interface (called from nonisolated classify())

    public func get(_ url: URL) -> CGSize? {
      state.withLock { $0.cache[url] }
    }

    /// Write a known size — called by ImageActor as a decode-time side effect so
    /// classify() gets a cache hit without a separate dimension probe.
    public func store(_ size: CGSize, for url: URL) {
      state.withLock { $0.cache[url] = size }
    }

    // MARK: - Async dimension fetch

    /// Cache hit → synchronous return (no allocation on hot path).
    /// In-flight hit → coalesces onto the existing Task; no duplicate network calls.
    ///   Priority note: the probe runs at the **first** caller's Task priority. Subsequent
    ///   waiters do not escalate it. Acceptable for Phase 1 (prefetch and scroll share
    ///   .userInitiated); flag for Phase 6 if priority inversion becomes measurable.
    /// Cache miss → `Range: bytes=0-1023` → ImageIO parse → cache + return.
    /// Returns nil on 416, parse failure, or insufficient header bytes.
    public func dimensions(for url: URL) async -> CGSize? {
      // Fast cache-only read — skips the wider critical section that also services
      // inFlight on a warm-cache hit. Working-range diff can re-request dimensions
      // for the same URL on every layout pass
      if let cached = get(url) { return cached }

      // Under a single lock: re-check cache (handles the race where a concurrent Task
      // stored the result between the fast-path read above and now), then coalesce inFlight.
      enum Outcome {
        case cached(CGSize)
        case task(Task<CGSize?, Never>)
      }
      let outcome: Outcome = state.withLock { st in
        if let size = st.cache[url] { return .cached(size) }
        if let task = st.inFlight[url] { return .task(task) }
        let t = Task<CGSize?, Never> {
          defer { self.state.withLock { $0.inFlight.removeValue(forKey: url) } }
          return await self.fetchAndParse(url: url)
        }
        st.inFlight[url] = t
        return .task(t)
      }
      switch outcome {
      case .cached(let size): return size
      case .task(let task): return await task.value
      }
    }

    // MARK: - Internal helpers (testable via @testable import)

    static func rangedRequest(for url: URL) -> URLRequest {
      var r = URLRequest(url: url)
      r.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
      return r
    }

    static func parse(from data: Data) -> CGSize? {
      let opts = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
      guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, opts) as? [CFString: Any]
      else { return nil }
      guard let w = (props[kCGImagePropertyPixelWidth] as? NSNumber).map(\.intValue),
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber).map(\.intValue),
        w > 0, h > 0
      else { return nil }
      return CGSize(width: w, height: h)
    }

    // MARK: - Private

    private func fetchAndParse(url: URL) async -> CGSize? {
      let request = Self.rangedRequest(for: url)
      guard let (data, response) = try? await session.data(for: request) else { return nil }

      if let http = response as? HTTPURLResponse {
        switch http.statusCode {
        case 206:
          break  // partial content — Range honored, expected path
        case 200:
          break  // server ignored Range, full body returned
        // Phase 6: emit os_signpost here to surface CDNs that strip Range headers
        default:
          return nil  // 416 range-not-satisfiable or error response
        }
      }

      guard let size = Self.parse(from: data) else { return nil }
      store(size, for: url)
      return size
    }
  }
#endif
