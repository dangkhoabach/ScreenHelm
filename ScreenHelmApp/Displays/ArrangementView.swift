import ScreenHelmCore
import SwiftUI

/// The displays as rectangles to drag into place, like the one in System
/// Settings, with lines that show when edges or centers line up.
struct ArrangementView: View {
    private let manager = DisplayManager.shared
    private let layout = LayoutGuard.shared
    /// Where the display being dragged is, in display coordinates.
    @State private var dragging: (id: CGDirectDisplayID, origin: CGPoint)?
    @State private var guides: [ArrangementGeometry.Guide] = []

    private var displays: [DisplayInfo] { manager.displays.filter { $0.mirrorOf == nil } }

    var body: some View {
        GeometryReader { proxy in
            let frames = currentFrames()
            let bounds = ArrangementGeometry.union(Array(frames.values)).insetBy(dx: -400, dy: -300)
            let scale = min(proxy.size.width / bounds.width, proxy.size.height / bounds.height)
            let offset = CGPoint(x: (proxy.size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                 y: (proxy.size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            ZStack(alignment: .topLeading) {
                ForEach(guides, id: \.self) { guide in
                    Path { path in
                        if guide.vertical {
                            path.move(to: CGPoint(x: guide.position * scale + offset.x, y: 0))
                            path.addLine(to: CGPoint(x: guide.position * scale + offset.x, y: proxy.size.height))
                        } else {
                            path.move(to: CGPoint(x: 0, y: guide.position * scale + offset.y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: guide.position * scale + offset.y))
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(displays) { display in
                    let frame = frames[display.id] ?? display.bounds
                    tile(display)
                        .frame(width: frame.width * scale - 2, height: frame.height * scale - 2)
                        .offset(x: frame.minX * scale + offset.x + 1, y: frame.minY * scale + offset.y + 1)
                        .gesture(DragGesture(coordinateSpace: .named("arrangement"))
                            .onChanged { value in
                                let proposed = CGPoint(x: display.bounds.minX + value.translation.width / scale,
                                                       y: display.bounds.minY + value.translation.height / scale)
                                let others = displays.filter { $0.id != display.id }.map(\.bounds)
                                let snapped = ArrangementGeometry.snap(CGRect(origin: proposed, size: display.bounds.size), to: others,
                                                                       tolerance: 14 / scale)
                                dragging = (display.id, snapped.origin)
                                guides = snapped.guides
                            }
                            .onEnded { _ in drop() })
                }
            }
            .coordinateSpace(name: "arrangement")
        }
        .frame(height: 220)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func currentFrames() -> [CGDirectDisplayID: CGRect] {
        var frames = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.bounds) })
        if let dragging, let size = frames[dragging.id]?.size { frames[dragging.id] = CGRect(origin: dragging.origin, size: size) }
        return frames
    }

    private func tile(_ display: DisplayInfo) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(display.isMain ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(dragging?.id == display.id ? Color.accentColor : Color.secondary, lineWidth: 1))
            .overlay {
                VStack(spacing: 2) {
                    Image(systemName: display.symbolName)
                    Text(verbatim: manager.name(of: display)).font(.caption2).lineLimit(1)
                }
                .padding(4)
            }
            .overlay(alignment: .top) {
                // The white strip of the menu bar, as System Settings draws it.
                if display.isMain { Rectangle().fill(.white.opacity(0.8)).frame(height: 4).clipShape(RoundedRectangle(cornerRadius: 2)).padding(2) }
            }
    }

    /// The dragged display is set against the nearest other one, so that
    /// the arrangement has no gap, and everything is moved to keep the
    /// main display at the origin.
    private func drop() {
        defer {
            self.dragging = nil
            guides = []
        }
        guard let dragging, let moved = displays.first(where: { $0.id == dragging.id }) else { return }
        let others = displays.filter { $0.id != moved.id }
        guard !others.isEmpty else { return }
        let placed = ArrangementGeometry.attach(CGRect(origin: dragging.origin, size: moved.bounds.size), to: others.map(\.bounds))
        var origins = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0.bounds.origin) })
        origins[moved.id] = placed.origin
        guard let main = displays.first(where: \.isMain), let mainOrigin = origins[main.id] else { return }
        for (id, origin) in origins { origins[id] = CGPoint(x: origin.x - mainOrigin.x, y: origin.y - mainOrigin.y) }
        // Moving the main display moves all the others instead.
        guard displays.contains(where: { origins[$0.id] != $0.bounds.origin }) else { return }
        layout.arrange(origins)
    }
}

/// The arithmetic of dragging one rectangle among others.
enum ArrangementGeometry {
    struct Guide: Hashable {
        var vertical: Bool
        var position: CGFloat
    }

    static func union(_ rects: [CGRect]) -> CGRect {
        rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
    }

    /// Pulls a rectangle's edges and center onto those of the others when
    /// they come within `tolerance`, and says along which lines.
    static func snap(_ rect: CGRect, to others: [CGRect], tolerance: CGFloat) -> (origin: CGPoint, guides: [Guide]) {
        var origin = rect.origin
        var guides: [Guide] = []
        func nearest(_ own: [CGFloat], _ targets: [CGFloat]) -> (shift: CGFloat, line: CGFloat)? {
            var best: (shift: CGFloat, line: CGFloat)?
            for value in own {
                for target in targets where abs(target - value) <= tolerance && abs(target - value) < abs(best?.shift ?? .infinity) {
                    best = (target - value, target)
                }
            }
            return best
        }
        if let x = nearest([rect.minX, rect.midX, rect.maxX], others.flatMap { [$0.minX, $0.midX, $0.maxX] }) {
            origin.x += x.shift
            guides.append(Guide(vertical: true, position: x.line))
        }
        if let y = nearest([rect.minY, rect.midY, rect.maxY], others.flatMap { [$0.minY, $0.midY, $0.maxY] }) {
            origin.y += y.shift
            guides.append(Guide(vertical: false, position: y.line))
        }
        return (origin, guides)
    }

    /// Moves a rectangle the shortest way so that it touches one of the
    /// others along an edge without overlapping any: displays can't
    /// overlap or float apart.
    static func attach(_ rect: CGRect, to others: [CGRect]) -> CGRect {
        var best: (rect: CGRect, distance: CGFloat)?
        for other in others {
            // Against each side of `other`, slid along it as far as the drag asked while still touching.
            let alongY = min(max(rect.minY, other.minY - rect.height + 1), other.maxY - 1)
            let alongX = min(max(rect.minX, other.minX - rect.width + 1), other.maxX - 1)
            let candidates = [
                CGRect(x: other.maxX, y: alongY, width: rect.width, height: rect.height),
                CGRect(x: other.minX - rect.width, y: alongY, width: rect.width, height: rect.height),
                CGRect(x: alongX, y: other.maxY, width: rect.width, height: rect.height),
                CGRect(x: alongX, y: other.minY - rect.height, width: rect.width, height: rect.height),
            ]
            for candidate in candidates where !others.contains(where: { $0.intersects(candidate.insetBy(dx: 0.5, dy: 0.5)) }) {
                let distance = hypot(candidate.minX - rect.minX, candidate.minY - rect.minY)
                if distance < (best?.distance ?? .infinity) { best = (candidate, distance) }
            }
        }
        return best?.rect ?? rect
    }
}
