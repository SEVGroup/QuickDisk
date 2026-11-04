import SwiftUI
import AppKit

// SquirrelDisk-style category families: one distinct hue per major folder,
// with nested levels changing lightness and saturation while keeping that hue.
private let categoryHues: [Double] = [0.82, 0.15, 0.36, 0.48, 0.53, 0.62, 0.70, 0.94]
private func categoryColor(_ index: Int, _ level: Int) -> Color {
    let depth = min(level, 5)
    return Color(hue: categoryHues[index % categoryHues.count],
                 saturation: max(0.46, 0.78 - Double(depth) * 0.065),
                 brightness: min(0.98, 0.84 + Double(depth) * 0.035))
}
struct ChartCell { let node: DiskNode; let path: Path; let color: Color; let gradientColor: Color }
struct DiskChart: View {
    let root: DiskNode; let depth: Int; let volumeCapacity: Int64?; let volumeFree: Int64?; let onOpen: (DiskNode) -> Void
    @State private var hovered: DiskNode?
    @State private var layout: [ChartCell] = []
    func cells(_ size: CGSize) -> [ChartCell] {
        var result: [ChartCell] = []
            let center = CGPoint(x: size.width / 2, y: size.height / 2); let outer = min(size.width, size.height) / 2 - 22
            func visibleDepth(_ node: DiskNode, _ remaining: Int) -> Int {
                guard remaining > 0 else { return 0 }
                var best = 0
                for child in node.children where child.bytes > 0 {
                    best = max(best, 1 + visibleDepth(child, remaining - 1))
                    if best == remaining { break }
                }
                return best
            }
            let levels = max(1, visibleDepth(root, depth))
            let inner = outer * 0.26; let width = (outer - inner) / CGFloat(levels)
            var volumeRoot = root
            while let parent = volumeRoot.parent { volumeRoot = parent }
            func familyIndex(for node: DiskNode, fallback: Int) -> Int {
                var anchor = node
                while let parent = anchor.parent, parent.id != volumeRoot.id { anchor = parent }
                guard anchor.parent?.id == volumeRoot.id else { return fallback }
                let siblings = volumeRoot.sorted.filter { $0.bytes > 0 }
                return siblings.firstIndex { $0.id == anchor.id } ?? fallback
            }
            func ring(_ node: DiskNode, _ start: Double, _ end: Double, _ level: Int, _ hue: Int) {
                guard level < depth else { return }
                var children = node.sorted.filter { $0.bytes > 0 }
                let isVolumeRoot = level == 0 && volumeCapacity != nil && volumeCapacity! > 0
                let scannedBytes = children.reduce(Int64(0)) { $0 + $1.bytes }
                let hiddenBytes = isVolumeRoot ? max(0, volumeCapacity! - (volumeFree ?? 0) - scannedBytes) : 0
                let freeBytes = isVolumeRoot ? max(0, volumeFree ?? 0) : 0
                if hiddenBytes > 0 {
                    let hidden = DiskNode(path: node.id + "/__quickdisk_hidden__", directory: false, bytes: hiddenBytes, logical: hiddenBytes)
                    hidden.synthetic = true; hidden.chartName = "Скрытое пространство"; children.append(hidden)
                }
                if freeBytes > 0 {
                    let free = DiskNode(path: node.id + "/__quickdisk_free__", directory: false, bytes: freeBytes, logical: freeBytes)
                    free.synthetic = true; free.chartName = "Свободное место"; children.append(free)
                }
                let total = Double(max(1, isVolumeRoot ? volumeCapacity! : children.reduce(Int64(0)) { $0 + $1.bytes }))
                let minimum = max(1, Int64(Double(root.bytes) * 0.005))
                let large = children.filter { $0.id.hasSuffix("/__quickdisk_hidden__") || $0.id.hasSuffix("/__quickdisk_free__") || $0.bytes >= minimum }
                let smallBytes = children.filter { !$0.id.hasSuffix("/__quickdisk_hidden__") && !$0.id.hasSuffix("/__quickdisk_free__") && $0.bytes < minimum }.reduce(Int64(0)) { $0 + $1.bytes }
                var displayed = large
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
                    let index = level == 0 ? i : familyIndex(for: c, fallback: hue)
                    let color: Color
                    if c.id.hasSuffix("/__quickdisk_hidden__") { color = Color(white: 0.68) }
                    else if c.id.hasSuffix("/__quickdisk_free__") { color = Color(white: 0.38) }
                    else { color = categoryColor(index, level) }
                    let adjacentColor: Color
                    if c.id.hasSuffix("/__quickdisk_hidden__") { adjacentColor = Color(white: 0.78) }
                    else if c.id.hasSuffix("/__quickdisk_free__") { adjacentColor = Color(white: 0.48) }
                    else { adjacentColor = categoryColor(index, level + 1) }
                    result.append(ChartCell(node: c, path: p, color: color, gradientColor: adjacentColor))
                    if c.isDirectory { ring(c, a, b, level + 1, index) }
                }
            }
            ring(root, -.pi / 2, 1.5 * .pi, 0, 0)
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
                VStack(spacing: 5) {
                        Text(humanSize(hovered?.bytes ?? root.bytes)).font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(hovered?.chartName ?? hovered?.name ?? root.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                }.frame(width: min(geometry.size.width, geometry.size.height) * 0.24).allowsHitTesting(false)
                if root.bytes == 0 { ContentUnavailableView("Нет данных для диаграммы", systemImage: "chart.pie", description: Text("Папка пуста или недоступна для чтения")) }
            }.task(id: "\(ObjectIdentifier(root))-\(geometry.size.width)-\(geometry.size.height)-\(depth)") { layout = cells(geometry.size); hovered = nil }
        }
    }
}
