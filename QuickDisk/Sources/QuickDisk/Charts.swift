import SwiftUI
import AppKit

// Top-level folders get distinct hues. SquirrelDisk keeps that hue family for
// descendants and progressively darkens it as the directory depth increases.
private let categoryHues: [Double] = [0.82, 0.15, 0.36, 0.48, 0.53, 0.62, 0.70, 0.94]
private let depthShade: [Double] = [0, -0.20, -0.35, -0.45, -0.55, -0.60]
private func rootColor(_ index: Int, _ level: Int = 0) -> Color {
    let depth = min(level, 5)
    return Color(hue: categoryHues[index % categoryHues.count],
                 saturation: max(0.46, 0.78 - Double(depth) * 0.065),
                 brightness: min(0.98, 0.84 + Double(depth) * 0.035))
}
private func inheritedColor(_ index: Int, _ level: Int) -> Color {
    let hue = categoryHues[index % categoryHues.count]
    let base = NSColor(calibratedHue: hue, saturation: 0.78, brightness: 0.84, alpha: 1)
        .usingColorSpace(.deviceRGB) ?? NSColor.systemBlue
    let scale = CGFloat(1 + depthShade[min(level, 5)])
    return Color(nsColor: NSColor(calibratedRed: base.redComponent * scale,
                                  green: base.greenComponent * scale,
                                  blue: base.blueComponent * scale, alpha: 1))
}
struct ChartCell { let node: DiskNode; let path: Path; let color: Color; let gradientColor: Color }
private struct ScanProgressOverlay: View {
    let progress: ScanProgress?

    private var percentLabel: String {
        guard let percent = progress?.percent else { return "…%" }
        return percent == 100 ? "100%" : "≈\(percent)%"
    }

    var body: some View {
        ZStack {
            DemFinalWaveView()
            VStack(spacing: 12) {
                Text(percentLabel)
                    .font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                    .lineLimit(1)
                    .fixedSize()
                Text("СКАНИРОВАНИЕ ДИСКА")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                if let progress {
                    VStack(spacing: 3) {
                        Text(progress.expectedFiles.map { "\(progress.files.formatted()) / ≈\($0.formatted())" }
                             ?? progress.files.formatted())
                            .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                        Text("ФАЙЛОВ ПРОСМОТРЕНО")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .tracking(1.4)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.78))
                } else {
                    Text("Подготовка сканирования")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Сканирование диска, \(percentLabel)")
        .allowsHitTesting(false)
    }
}

struct DiskChart: View {
    let root: DiskNode; let depth: Int; let volumeCapacity: Int64?; let volumeFree: Int64?; var isScanning = false; var scanProgress: ScanProgress?; let onOpen: (DiskNode) -> Void
    @State private var hovered: DiskNode?
    @State private var layout: [ChartCell] = []
    func cells(_ size: CGSize) -> [ChartCell] {
        var result: [ChartCell] = []
            let center = CGPoint(x: size.width / 2, y: size.height / 2); let outer = min(size.width, size.height) / 2 - 22
            func visibleDepth(_ node: DiskNode, _ remaining: Int) -> Int {
                guard remaining > 0 else { return 0 }
                var best = 0
                for child in TopItems.largest(node.children, limit: 120) where child.bytes > 0 {
                    best = max(best, 1 + visibleDepth(child, remaining - 1))
                    if best == remaining { break }
                }
                return best
            }
            let levels = max(1, visibleDepth(root, depth))
            let inner = outer * 0.26; let width = (outer - inner) / CGFloat(levels)
            var volumeRoot = root
            while let parent = volumeRoot.parent { volumeRoot = parent }
            func ring(_ node: DiskNode, _ start: Double, _ end: Double, _ level: Int, _ hue: Int?) {
                guard level < depth else { return }
                let children = TopItems.largest(node.children, limit: 120).filter { $0.bytes > 0 }
                let isVolumeRoot = level == 0 && volumeCapacity != nil && volumeCapacity! > 0
                let scannedBytes = node.bytes
                let hiddenBytes = isVolumeRoot ? max(0, volumeCapacity! - (volumeFree ?? 0) - scannedBytes) : 0
                let freeBytes = isVolumeRoot ? max(0, volumeFree ?? 0) : 0
                let total = Double(max(1, isVolumeRoot ? volumeCapacity! : node.bytes))
                let minimum = max(1, Int64(Double(root.bytes) * 0.005))
                var displayed = children.filter { $0.bytes >= minimum }
                let shownBytes = displayed.reduce(Int64(0)) { $0 + $1.bytes }
                let smallBytes = max(0, node.bytes - shownBytes)
                if hiddenBytes > 0 {
                    let hidden = DiskNode(path: node.id + "/__quickdisk_hidden__", directory: false, bytes: hiddenBytes, logical: hiddenBytes)
                    hidden.synthetic = true; hidden.chartName = "Скрытое пространство"; displayed.append(hidden)
                }
                if freeBytes > 0 {
                    let free = DiskNode(path: node.id + "/__quickdisk_free__", directory: false, bytes: freeBytes, logical: freeBytes)
                    free.synthetic = true; free.chartName = "Свободное место"; displayed.append(free)
                }
                if smallBytes > 0 {
                    let smaller = DiskNode(path: node.id + "/… мелкие элементы", directory: false, bytes: smallBytes, logical: smallBytes)
                    smaller.synthetic = true; displayed.append(smaller)
                }
                var a = start
                for (i, c) in displayed.enumerated() {
                    let b = a + (end - start) * Double(c.bytes) / total
                    defer { a = b }
                    let pad = min(0.005, (b - a) / 2)
                    let startAngle = a + pad / 2, endAngle = b - pad / 2
                    if endAngle - startAngle < 0.001 { continue }
                    let r1 = inner + CGFloat(level) * width + 1.5; let r2 = r1 + width - 3
                    var p = Path(); p.addArc(center: center, radius: r2, startAngle: .radians(startAngle), endAngle: .radians(endAngle), clockwise: false)
                    p.addArc(center: center, radius: r1, startAngle: .radians(endAngle), endAngle: .radians(startAngle), clockwise: true); p.closeSubpath()
                    // Descendants inherit the hue of their first-level folder.
                    // Only the root ring advances through the palette.
                    let family = level == 0 ? i : (hue ?? i)
                    let color: Color
                    let adjacentColor: Color
                    if c.id.hasSuffix("/__quickdisk_hidden__") {
                        color = Color(white: 0.68); adjacentColor = Color(white: 0.78)
                    } else if c.id.hasSuffix("/__quickdisk_free__") {
                        color = Color(white: 0.38); adjacentColor = Color(white: 0.48)
                    } else if level == 0 {
                        color = rootColor(family, 0)
                        adjacentColor = rootColor(family, 1)
                    } else {
                        color = inheritedColor(family, min(level + 1, 5))
                        adjacentColor = inheritedColor(family, min(level + 2, 5))
                    }
                    let opacity = c.isDirectory ? 0.6 : 0.4
                    result.append(ChartCell(node: c, path: p, color: color.opacity(opacity), gradientColor: adjacentColor.opacity(opacity)))
                    if c.isDirectory { ring(c, a, b, level + 1, family) }
                }
            }
            ring(root, -.pi / 2, 1.5 * .pi, 0, nil)
        return result
    }
    var body: some View {
        GeometryReader { geometry in
            // ImageRenderer (used by PDF export) does not run view .task handlers.
            // Build the same geometry synchronously when no cached screen layout exists.
            let items = layout.isEmpty ? cells(geometry.size) : layout
            ZStack {
                Canvas { context, size in
                    for cell in items {
                        let gradient = Gradient(colors: [cell.color, cell.gradientColor, cell.color])
                        context.fill(cell.path, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                        let isHovered = hovered?.id == cell.node.id
                        if isHovered { context.fill(cell.path, with: .color(Color.white.opacity(0.16))) }
                        context.stroke(cell.path, with: .color(isHovered ? Color.white.opacity(0.95) : Color.black.opacity(0.9)), lineWidth: isHovered ? 2.8 : 2.0)
                    }
                }
                .onContinuousHover { phase in
                    if case let .active(point) = phase {
                        hovered = items.reversed().first { $0.path.contains(point) }?.node
                        if hovered != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    } else { hovered = nil; NSCursor.arrow.set() }
                }
                .onTapGesture { point in
                    if let n = items.reversed().first(where: { $0.path.contains(point) })?.node, n.isDirectory { onOpen(n) }
                    else if let parent = root.parent, hypot(point.x - geometry.size.width / 2, point.y - geometry.size.height / 2) < (min(geometry.size.width, geometry.size.height) / 2 - 22) * 0.26 { onOpen(parent) }
                }
                .help("Нажмите на папку, чтобы открыть. В центре кольца — возврат к родителю.")
                if isScanning { ScanProgressOverlay(progress: scanProgress) }
                if !isScanning { VStack(spacing: 5) {
                        Text(humanSize(hovered?.bytes ?? root.bytes)).font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(hovered?.chartName ?? hovered?.name ?? root.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                }.frame(width: min(geometry.size.width, geometry.size.height) * 0.24).allowsHitTesting(false) }
                if root.bytes == 0 { ContentUnavailableView("Нет данных для диаграммы", systemImage: "chart.pie", description: Text("Папка пуста или недоступна для чтения")) }
            }.task(id: "\(ObjectIdentifier(root))-\(geometry.size.width)-\(geometry.size.height)-\(depth)") { layout = cells(geometry.size); hovered = nil }
        }
    }
}
