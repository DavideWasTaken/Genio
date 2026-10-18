import XCTest
@testable import GenioCore

final class FramePacerTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  func testAtMostOneFramePerSecondAndOneInFlight() {
    var pacer = FramePacer(framesPerSecond: 5)  // capped at 1
    XCTAssertEqual(pacer.framesPerSecond, 1)
    XCTAssertEqual(pacer.decide(frameTime: t0, now: t0 + 0.1), .send)
    XCTAssertEqual(pacer.decide(frameTime: t0 + 0.2, now: t0 + 0.3), .skip(.busy))
    pacer.finished(frameTime: t0, now: t0 + 0.4, sent: true)
    XCTAssertEqual(pacer.decide(frameTime: t0 + 0.5, now: t0 + 0.6), .skip(.tooSoon))
    XCTAssertEqual(pacer.decide(frameTime: t0 + 1.4, now: t0 + 1.5), .send)
    pacer.finished(frameTime: t0 + 1.4, now: t0 + 1.6, sent: true)
    XCTAssertEqual(pacer.metrics.sent, 2)
    XCTAssertEqual(pacer.metrics.droppedBusy, 1)
    XCTAssertGreaterThan(pacer.metrics.averageLatency, 0)
  }

  func testStaleSameAndPaused() {
    var pacer = FramePacer(framesPerSecond: 1, maxFrameAge: 1.5)
    XCTAssertEqual(pacer.decide(frameTime: nil, now: t0), .skip(.noFrame))
    XCTAssertEqual(pacer.decide(frameTime: t0, now: t0 + 3), .skip(.stale))
    XCTAssertEqual(pacer.decide(frameTime: t0 + 3, now: t0 + 3.1), .send)
    pacer.finished(frameTime: t0 + 3, now: t0 + 3.2, sent: false)
    XCTAssertEqual(pacer.metrics.failed, 1)
    XCTAssertEqual(pacer.decide(frameTime: t0 + 3, now: t0 + 5), .skip(.sameFrame))
    pacer.paused = true
    XCTAssertEqual(pacer.decide(frameTime: t0 + 6, now: t0 + 6), .skip(.paused))
  }

  func testSlowerRates() {
    var pacer = FramePacer(framesPerSecond: 0.5)
    XCTAssertEqual(pacer.interval, 2)
    XCTAssertEqual(pacer.decide(frameTime: t0, now: t0), .send)
    pacer.finished(frameTime: t0, now: t0, sent: true)
    XCTAssertEqual(pacer.decide(frameTime: t0 + 1.5, now: t0 + 1.5), .skip(.tooSoon))
    XCTAssertEqual(pacer.decide(frameTime: t0 + 2, now: t0 + 2), .send)
  }
}

final class PCMTests: XCTestCase {
  func testRoundTrip() {
    let samples: [Float] = [0, 0.5, -0.5, 1, -1, 2]
    let data = PCM.int16Data(from: samples)
    XCTAssertEqual(data.count, 12)
    XCTAssertEqual(Array(data.prefix(4)), [0, 0, 0xFF, 0x3F], "little-endian 16383")
    let back = PCM.floatSamples(fromInt16: data)
    XCTAssertEqual(back.count, 6)
    XCTAssertEqual(back[1], 0.5, accuracy: 0.001)
    XCTAssertEqual(back[5], 1, accuracy: 0.001, "clipped")
    XCTAssertEqual(PCM.floatSamples(fromInt16: Data([1])).count, 0)
  }

  func testLevelAndDuration() {
    XCTAssertEqual(PCM.level(ofInt16: PCM.int16Data(from: [Float](repeating: 0, count: 100))), 0)
    XCTAssertEqual(PCM.level(ofInt16: PCM.int16Data(from: [Float](repeating: 0.5, count: 100))), 0.5, accuracy: 0.01)
    XCTAssertEqual(PCM.duration(bytes: 32_000, rate: 16_000), 1)
  }
}

final class LiveInstructionsTests: XCTestCase {
  @MainActor
  func testInstructionsCarryTheTask() throws {
    let engine = TaskEngine()
    try engine.startTask(goal: "Filtro", steps: ["a", "b", "c"], strict: true).get()
    let text = LiveInstructions.system(language: "Italian", snapshot: engine.snapshot())
    XCTAssertTrue(text.contains("Speak Italian"))
    XCTAssertTrue(text.contains("[NOW] 1. a"))
    XCTAssertTrue(LiveInstructions.system(language: "English", snapshot: nil).contains("No task in progress"))
    XCTAssertTrue(LiveInstructions.contextRecovery(snapshot: engine.snapshot()).hasPrefix("[Genio]"))

    engine.userConfirmedStep()
    let task = engine.task!
    XCTAssertNil(LiveInstructions.stepEvent(.stepChanged(task, reason: .userConfirmed)), "the model already knows")
    XCTAssertTrue(LiveInstructions.stepEvent(.stepChanged(task, reason: .verified))?.contains("b") == true)
  }
}
