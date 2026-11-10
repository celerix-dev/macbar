import Foundation
import IOKit.ps
import Darwin

struct SystemStats: Codable {
    let battery: Int
    let isCharging: Bool
    let hasBattery: Bool
    let cpuPercent: Int
    let memoryUsedGB: Double
    let memoryTotalGB: Double
    let memoryPercent: Int
    let memoryFormatted: String
    let volume: Int
    let isMuted: Bool
}

final class SystemMonitor {
    static let shared = SystemMonitor()

    private var prevCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    init() {
        // Prime the CPU ticks baseline
        _ = fetchCPUUsage()
    }

    func fetchStats() -> SystemStats {
        let (battery, isCharging, hasBattery) = fetchBattery()
        let cpuPercent = fetchCPUUsage()
        let (usedGB, totalGB, memPercent, memFormatted) = fetchMemoryUsage()
        let (volume, isMuted) = VolumeMonitor.shared.fetchVolumeAndMute()

        return SystemStats(
            battery: battery,
            isCharging: isCharging,
            hasBattery: hasBattery,
            cpuPercent: cpuPercent,
            memoryUsedGB: usedGB,
            memoryTotalGB: totalGB,
            memoryPercent: memPercent,
            memoryFormatted: memFormatted,
            volume: volume,
            isMuted: isMuted
        )
    }

    private func fetchBattery() -> (Int, Bool, Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (100, false, false)
        }

        for ps in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] {
                let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 100
                let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
                let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
                let percent = max > 0 ? Int((Double(current) / Double(max)) * 100.0) : 100
                return (percent, isCharging, true)
            }
        }
        return (100, false, false)
    }

    private func fetchCPUUsage() -> Int {
        var cpuLoadInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let user = cpuLoadInfo.cpu_ticks.0
        let system = cpuLoadInfo.cpu_ticks.1
        let idle = cpuLoadInfo.cpu_ticks.2
        let nice = cpuLoadInfo.cpu_ticks.3

        defer {
            prevCPUTicks = (user, system, idle, nice)
        }

        guard let prev = prevCPUTicks else {
            return 0
        }

        let userDiff = Double(user >= prev.user ? user - prev.user : 0)
        let sysDiff = Double(system >= prev.system ? system - prev.system : 0)
        let idleDiff = Double(idle >= prev.idle ? idle - prev.idle : 0)
        let niceDiff = Double(nice >= prev.nice ? nice - prev.nice : 0)

        let totalDiff = userDiff + sysDiff + idleDiff + niceDiff
        guard totalDiff > 0 else { return 0 }

        let usage = ((userDiff + sysDiff + niceDiff) / totalDiff) * 100.0
        return max(0, min(100, Int(round(usage))))
    }

    private func fetchMemoryUsage() -> (Double, Double, Int, String) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
        let totalGrounded = Double(Int(round(totalGB)))

        guard result == KERN_SUCCESS else {
            return (0.0, totalGrounded, 0, "0 / \(Int(totalGrounded))Gb")
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pageSize64 = UInt64(pageSize > 0 ? pageSize : 4096)

        let active = UInt64(stats.active_count) * pageSize64
        let wired = UInt64(stats.wire_count) * pageSize64
        let compressed = UInt64(stats.compressor_page_count) * pageSize64
        let usedBytes = active + wired + compressed

        let usedGB = Double(usedBytes) / (1024.0 * 1024.0 * 1024.0)
        let percentage = totalBytes > 0 ? Int(round((Double(usedBytes) / Double(totalBytes)) * 100.0)) : 0

        let usedRounded = Double(round(usedGB * 10) / 10)
        let usedFormatted = String(format: "%.1f", usedGB)
        let formatted = "\(usedFormatted) / \(Int(totalGrounded))Gb"
        return (usedRounded, totalGrounded, max(0, min(100, percentage)), formatted)
    }
}
