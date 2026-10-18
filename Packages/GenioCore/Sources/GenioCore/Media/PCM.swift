import Foundation

/// 16-bit little-endian PCM helpers for the Live API (16 kHz in, 24 kHz out).
public enum PCM {
  /// Float samples (-1…1) to 16-bit little-endian bytes.
  public static func int16Data(from samples: UnsafeBufferPointer<Float>) -> Data {
    var data = Data(count: samples.count * 2)
    data.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: Int16.self)
      for (index, sample) in samples.enumerated() {
        let clipped = max(-1, min(1, sample))
        out[index] = Int16(clipped * Float(Int16.max)).littleEndian
      }
    }
    return data
  }

  public static func int16Data(from samples: [Float]) -> Data {
    samples.withUnsafeBufferPointer { int16Data(from: $0) }
  }

  /// 16-bit little-endian bytes to float samples (-1…1). A trailing odd byte
  /// is ignored.
  public static func floatSamples(fromInt16 data: Data) -> [Float] {
    let count = data.count / 2
    var samples = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
      for index in 0..<count {
        let low = UInt16(raw[index * 2])
        let high = UInt16(raw[index * 2 + 1])
        samples[index] = Float(Int16(bitPattern: low | high << 8)) / 32768
      }
    }
    return samples
  }

  /// Root-mean-square level of 16-bit audio, 0…1 (for the mic test meter).
  public static func level(ofInt16 data: Data) -> Float {
    let samples = floatSamples(fromInt16: data)
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(samples.count)).squareRoot()
  }

  /// Seconds of audio in 16-bit mono bytes at `rate`.
  public static func duration(bytes: Int, rate: Int) -> TimeInterval {
    TimeInterval(bytes / 2) / TimeInterval(rate)
  }
}
