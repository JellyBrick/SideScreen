import Foundation

// Line-buffered stdout so redirected logs stream in real time.
setvbuf(stdout, nil, _IOLBF, 0)

// AOA PoC harness (plan Phase 0). Answers, with numbers, whether AOA bulk
// transport clears the go/no-go gates before the production implementation:
//   GATE A: switch+claim works on macOS 13+ (with or without kill-adb dance)
//   GATE B: SuperSpeed devices sustain ≥800 Mbps, RTT p99 ≤5ms, 0 errors
//   GATE C: High-Speed devices sustain ≥250 Mbps with better jitter than adb
//   GATE D: 30-min soak + replug recovery (run with --seconds 1800, replug 10x)

let usage = """
usage: AOATest <command> [options]

commands:
  probe                     list Android/accessory USB devices (registry only,
                            never opens a device) with link speed + interfaces
  switch [--kill-adb]       send the AOA v2 switch sequence; --kill-adb stops
         [--serial S]       the adb server first (exclusive-access fallback)
         [--retry N]        and restarts it after re-enumeration. Retries the
         [--no-retry]       sequence when Android's 10s enter-timeout reverts
                            the mode before the Mac finishes enumerating
                            (observed on Galaxy Tab SS+ links; default 2)
  reset                     reset an accessory-mode device back to normal mode
  bench [options]           bulk throughput/latency benchmark to the aoabench
                            Android app (must already be in accessory mode)
  bench --tcp [options]     same benchmark over adb reverse TCP as a baseline

bench options:
  --seconds N     duration (default 30; use 1800 for the GATE D soak)
  --chunk-kb N    payload per block in KB (default 16; try 64, 256)
  --inflight N    outstanding transfers (default 4; try 1, 8)
  --no-verify     skip checksumming (measures raw pump speed)
  --port N        TCP port for --tcp mode (default 54399)
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(1)
}
args.removeFirst()

func intOption(_ name: String, default def: Int) -> Int {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count, let v = Int(args[idx + 1]) else {
        return def
    }
    return v
}

func flag(_ name: String) -> Bool { args.contains(name) }

func stringOption(_ name: String) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

do {
    switch command {
    case "probe":
        USBProbe.printReport()

    case "switch":
        try AOASwitch.performSwitch(
            serial: stringOption("--serial"),
            killAdb: flag("--kill-adb"),
            retries: flag("--no-retry") ? 0 : intOption("--retry", default: 2))

    case "reset":
        try AOASwitch.resetAccessory()

    case "bench":
        var config = BenchConfig()
        config.seconds = intOption("--seconds", default: 30)
        config.chunkKB = intOption("--chunk-kb", default: 16)
        config.inflight = intOption("--inflight", default: 4)
        config.verify = !flag("--no-verify")
        if flag("--tcp") {
            let port = UInt16(intOption("--port", default: 54399))
            try TCPBenchRunner.run(config: config, port: port)
        } else {
            try AOABenchRunner.run(config: config)
        }

    default:
        print(usage)
        exit(1)
    }
} catch {
    print("❌ \(error)")
    exit(1)
}
