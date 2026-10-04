import AVFoundation
import Vision

/// One Euro filter: heavy smoothing when still, low lag when moving fast.
struct OneEuro {
    var minCutoff: Double
    var beta: Double
    private var dCutoff = 1.0
    private var x: Double?
    private var dx = 0.0

    init(minCutoff: Double, beta: Double) { self.minCutoff = minCutoff; self.beta = beta }

    mutating func filter(_ v: Double, dt: Double) -> Double {
        func alpha(_ c: Double) -> Double { 1 / (1 + (1 / (2 * Double.pi * c)) / dt) }
        guard let px = x else { x = v; return v }
        dx += alpha(dCutoff) * ((v - px) / dt - dx)
        let nx = px + alpha(minCutoff + beta * abs(dx)) * (v - px)
        x = nx
        return nx
    }

    mutating func reset() { x = nil; dx = 0 }
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

/// Camera → Vision face landmarks → a steady nose position in normalised image coordinates
/// (origin bottom-left, not mirrored). Runs on its own queue; read `latest` from anywhere.
final class NoseTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "quickcapture.nosecontrol.camera")
    private let request = VNDetectFaceLandmarksRequest()
    private var history: [[Double]] = []
    private var smooth: [Double]?
    private var lastSeen = Date.distantPast

    private let lock = NSLock()
    private var _latest: [Double]?
    private var _latestAt = Date.distantPast

    /// The newest nose position, or nil if no face was seen in the last 0.3 s.
    var latest: [Double]? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_latestAt) < 0.3 ? _latest : nil
    }

    func start() throws {
        guard !session.isRunning else { return }
        guard let device = AVCaptureDevice.default(for: .video) else { throw AppError("No camera found.") }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AppError("The camera is in use by another app.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        queue.sync { history = []; smooth = nil }
        lock.lock(); _latest = nil; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sb) else { return }
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = face.landmarks,
              let nose = landmarks.nose?.normalizedPoints, !nose.isEmpty else {
            if Date().timeIntervalSince(lastSeen) > 0.3 { history = []; smooth = nil }
            return
        }
        lastSeen = Date()
        // Average the nose tip region and the nose bridge: independent errors cancel, so the
        // result is steadier than any single landmark.
        var points = nose
        if let crest = landmarks.noseCrest?.normalizedPoints, !crest.isEmpty { points += crest }
        let cx = points.map { Double($0.x) }.reduce(0, +) / Double(points.count)
        let cy = points.map { Double($0.y) }.reduce(0, +) / Double(points.count)
        let box = face.boundingBox
        let raw = [Double(box.minX) + cx * Double(box.width), Double(box.minY) + cy * Double(box.height)]

        // Median of 7 frames drops outliers; a light EMA removes what is left.
        history.append(raw)
        if history.count > 7 { history.removeFirst() }
        let med = (0..<2).map { j in median(history.map { $0[j] }) }
        if let s = smooth { smooth = (0..<2).map { s[$0] + 0.4 * (med[$0] - s[$0]) } } else { smooth = med }

        lock.lock(); _latest = smooth; _latestAt = Date(); lock.unlock()
    }
}
