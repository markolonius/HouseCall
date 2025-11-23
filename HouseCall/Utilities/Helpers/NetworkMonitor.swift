//
//  NetworkMonitor.swift
//  HouseCall
//
//  Network connectivity monitoring for HIPAA-compliant error handling
//

import Foundation
import Network
import Combine

/// Monitors network connectivity status for graceful offline handling
@MainActor
class NetworkMonitor: ObservableObject {
    /// Shared singleton instance
    static let shared = NetworkMonitor()

    /// Current network connectivity status
    @Published private(set) var isConnected: Bool = true

    /// Network path monitor
    private let monitor: NWPathMonitor

    /// Queue for network monitoring
    private let queue = DispatchQueue(label: "com.housecall.networkmonitor")

    private init() {
        monitor = NWPathMonitor()
        startMonitoring()
    }

    /// Start monitoring network connectivity
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring (cleanup)
    func stopMonitoring() {
        monitor.cancel()
    }

    deinit {
        stopMonitoring()
    }
}
