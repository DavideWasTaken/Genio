import Foundation

/// How sharp a frame is, to pick the best of a few for a close look: frames
/// from glasses on a moving head are often blurred, and a blurred label
/// cannot be read however good the model.
public enum Sharpness {
  /// The variance of the Laplacian of a grayscale image (row-major, one byte
  /// per pixel): high for crisp edges, low for blur. Only comparable between
  /// images of the same size and scene.
  public static func score(gray: [UInt8], width: Int, height: Int) -> Double {
    guard width >= 3, height >= 3, gray.count >= width * height else { return 0 }
    var sum = 0.0
    var sumSquares = 0.0
    var count = 0.0
    for y in 1..<(height - 1) {
      let row = y * width
      for x in 1..<(width - 1) {
        let i = row + x
        let laplacian = Double(gray[i - 1]) + Double(gray[i + 1]) + Double(gray[i - width]) + Double(gray[i + width])
          - 4 * Double(gray[i])
        sum += laplacian
        sumSquares += laplacian * laplacian
        count += 1
      }
    }
    let mean = sum / count
    return sumSquares / count - mean * mean
  }
}
