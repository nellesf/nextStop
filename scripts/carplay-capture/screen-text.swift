import AppKit
import Foundation
import ImageIO
import Vision

// OCR is used only to locate real controls for mouse interaction. It never
// changes a screenshot or draws content into a captured image.
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "display" {
  let bounds = CGDisplayBounds(CGMainDisplayID())
  let value: [String: Double] = [
    "x": bounds.minX, "y": bounds.minY,
    "width": bounds.width, "height": bounds.height,
  ]
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
} else {
  guard CommandLine.arguments.count == 2,
    let source = CGImageSourceCreateWithURL(
      URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { fatalError("Usage: screen-text <PNG path> or screen-text display") }
  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.recognitionLanguages = ["de-DE", "en-US"]
  request.usesLanguageCorrection = true
  try VNImageRequestHandler(cgImage: image).perform([request])
  let words: [[String: Any]] = (request.results ?? []).compactMap { observation in
    guard let candidate = observation.topCandidates(1).first else { return nil }
    return [
      "text": candidate.string,
      "confidence": candidate.confidence,
      "x": observation.boundingBox.minX * Double(image.width),
      "y": (1 - observation.boundingBox.maxY) * Double(image.height),
      "width": observation.boundingBox.width * Double(image.width),
      "height": observation.boundingBox.height * Double(image.height),
    ]
  }
  let result: [String: Any] = ["width": image.width, "height": image.height, "text": words]
  let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}
