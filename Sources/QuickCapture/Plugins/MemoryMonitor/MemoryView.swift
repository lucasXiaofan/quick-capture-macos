import AppKit
import Charts
import SwiftUI

struct MemoryView: View {
    @ObservedObject var plugin: MemoryMonitorPlugin
    @ObservedObject var sampler: MemorySampler
    @ObservedObject var state: AppState

    static func gb(_ bytes: Double) -> String { String(format: "%.1f GB", bytes / 1_073_741_824) }

    private struct Point: Identifiable {
        let id = UUID(); let time: Date; let series: String; let gb: Double
    }

    private var points: [Point] {
        sampler.history.flatMap { s -> [Point] in
            [Point(time: s.time, series: "Used", gb: s.used / 1e9 * 0.931322575),
             Point(time: s.time, series: "Cached files", gb: s.cached / 1e9 * 0.931322575),
             Point(time: s.time, series: "Free + cached", gb: (s.free + s.cached) / 1e9 * 0.931322575)]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = sampler.latest {
                    header(s)
                    bar(s)
                    chart(s)
                    baselineRow(s)
                }
                appsSection
                if !sampler.processes.isEmpty { processesSection }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 560)
    }

    // MARK: Sections

    private func header(_ s: MemSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text("\(Self.gb(s.used)) used of \(Self.gb(s.total))").font(.title2.bold())
                Text("\(Self.gb(s.available)) left for a new model before swapping  ·  swap \(Self.gb(s.swapUsed))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            let (label, color): (String, Color) = s.pressure >= 4 ? ("Critical", .red) : s.pressure == 2 ? ("Warning", .orange) : ("Normal", .green)
            Label("Pressure: \(label)", systemImage: "circle.fill").foregroundStyle(color).font(.callout)
        }
    }

    private func bar(_ s: MemSample) -> some View {
        let parts: [(String, Double, Color)] = [
            ("App", s.app, .blue), ("Wired", s.wired, .orange), ("Compressed", s.compressed, .purple),
            ("Cached files", s.cached, .teal), ("Free", s.free, Color.gray.opacity(0.35)),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: max(1, geo.size.width * p.1 / s.total))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 4))
            }.frame(height: 18)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 4) {
                        Circle().fill(p.2).frame(width: 8, height: 8)
                        Text("\(p.0) \(Self.gb(p.1))").font(.caption)
                    }
                }
            }
            Text("Cached files hold mmap'd model weights (llama.cpp / LM Studio): not in \"used\", not in any app's Memory column, given back when needed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func chart(_ s: MemSample) -> some View {
        Chart(points) { p in
            LineMark(x: .value("Time", p.time), y: .value("GB", p.gb))
                .foregroundStyle(by: .value("Series", p.series))
        }
        .chartForegroundStyleScale(["Used": Color.blue, "Cached files": Color.teal, "Free + cached": Color.gray])
        .chartYScale(domain: 0...(s.total / 1.073741824e9))
        .chartYAxisLabel("GiB")
        .frame(height: 220)
    }

    private func baselineRow(_ s: MemSample) -> some View {
        HStack {
            if let b = sampler.baseline {
                let d = { (x: Double) in (x >= 0 ? "+" : "−") + Self.gb(abs(x)) }
                Text("Since baseline (\(b.time, style: .time)):  used \(d(s.used - b.used))  ·  cached files \(d(s.cached - b.cached))  ·  swap \(d(s.swapUsed - b.swapUsed))")
                    .font(.callout.monospacedDigit())
                Spacer()
                Button("Clear") { sampler.baseline = nil }
            } else {
                Text("Set a baseline, load a model, and read what it cost.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            Button("Set Baseline Now") { sampler.baseline = s }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apps").font(.headline)
                Spacer()
                Button("Quit All Not Kept…") { plugin.quitAllUnkept() }
            }
            ForEach(sampler.apps) { app in
                HStack {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                    Text(app.name)
                    Spacer()
                    Text(Self.gb(app.footprint)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Toggle("Keep", isOn: Binding(get: { plugin.isKept(app) }, set: { plugin.setKept(app, $0) }))
                        .toggleStyle(.checkbox).disabled(app.bundleID == "com.apple.finder" || app.bundleID == Bundle.main.bundleIdentifier)
                    Button("Quit") { app.app.terminate() }.disabled(plugin.isKept(app))
                }
                .contextMenu { Button("Force Quit") { app.app.forceTerminate() } }
            }
        }
    }

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Other big processes (not part of an app above)").font(.headline)
            ForEach(sampler.processes) { p in
                HStack {
                    Text(p.name)
                    Text("pid \(p.id)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if p.mapped > 200_000_000 {
                        Text("+ \(Self.gb(p.mapped)) mapped files (model weights, in Cached files)")
                            .font(.caption).foregroundStyle(.teal)
                    }
                    Text(Self.gb(p.footprint)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Stop") { plugin.terminate(p) }
                }
            }
        }
    }
}
