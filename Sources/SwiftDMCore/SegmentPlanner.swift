import Foundation

/// Decides how a file is cut into byte ranges, including IDM-style dynamic segmentation:
/// when a connection finishes early it takes over half of the largest range still in flight.
public enum SegmentPlanner {
    public static let minimumSegmentSize: Int64 = 256 * 1024

    public static func initialSegments(totalBytes: Int64, connections: Int, minSize: Int64 = minimumSegmentSize) -> [Segment] {
        if totalBytes == 0 { return [] }
        guard totalBytes > 0 else { return [Segment(id: 0, start: 0, end: -1)] }
        let byMinSize = max(1, totalBytes / max(1, minSize))
        let count = Int(max(1, min(Int64(max(1, connections)), byMinSize)))
        let size = totalBytes / Int64(count)
        return (0..<count).map { index in
            let start = Int64(index) * size
            let end = index == count - 1 ? totalBytes - 1 : start + size - 1
            return Segment(id: index, start: start, end: end)
        }
    }

    /// Splits the active segment with the most bytes left in two and returns the index of the new half.
    /// The connection serving the original segment keeps going and stops at the new boundary.
    public static func split(_ segments: inout [Segment], active: Set<Int>, minSize: Int64 = minimumSegmentSize) -> Int? {
        let candidates = active.filter { segments.indices.contains($0) && segments[$0].end >= 0 && !segments[$0].isComplete }
        guard let index = candidates.max(by: { segments[$0].remaining < segments[$1].remaining }) else { return nil }
        let segment = segments[index]
        guard segment.remaining >= 2 * minSize else { return nil }
        let boundary = segment.position + segment.remaining / 2
        segments.append(Segment(id: segments.count, start: boundary, end: segment.end))
        segments[index].end = boundary - 1
        return segments.count - 1
    }

    /// First unfinished segment nobody is working on.
    public static func nextIdle(_ segments: [Segment], active: Set<Int>, excluding cooling: Set<Int> = []) -> Int? {
        segments.indices.first { !segments[$0].isComplete && !active.contains($0) && !cooling.contains($0) }
    }
}
