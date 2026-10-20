import XCTest
@testable import GenioCore

final class RemarkDeliveryTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000)
  private let step = RemarkDelivery.StepRef(index: 2, revision: 3)

  private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  private func sent(_ events: [RemarkDelivery.Event]) -> [String] {
    events.compactMap { if case .send(let remark, _) = $0 { return remark.text } else { return nil } }
  }

  func testSentWhenQuietAndHeard() {
    var delivery = RemarkDelivery()
    delivery.queue("Attento, la pentola è calda", kind: .hazard, step: step, now: at(0))
    // Genio is speaking: wait.
    XCTAssertEqual(sent(delivery.tick(now: at(0.2), step: step, canSpeak: false, lastUserSpeech: nil)), [])
    // The user just spoke: a hazard waits one second.
    XCTAssertEqual(sent(delivery.tick(now: at(0.5), step: step, canSpeak: true, lastUserSpeech: at(0))), [])
    XCTAssertEqual(sent(delivery.tick(now: at(1.5), step: step, canSpeak: true, lastUserSpeech: at(0))), ["Attento, la pentola è calda"])
    // In flight: not sent twice.
    XCTAssertEqual(sent(delivery.tick(now: at(2), step: step, canSpeak: true, lastUserSpeech: nil)), [])
    let events = delivery.genioFinishedTurn("Occhio, la pentola scotta!", now: at(4))
    XCTAssertEqual(events.count, 1)
    guard case .delivered = events.first else { return XCTFail("expected delivered, got \(events)") }
    XCTAssertTrue(delivery.isIdle)
  }

  func testInterruptedIsSentAgainThenGivenUp() {
    var delivery = RemarkDelivery()
    delivery.queue("La vite lunga va sotto", kind: .mistake, step: step, now: at(0))
    XCTAssertEqual(sent(delivery.tick(now: at(3), step: step, canSpeak: true, lastUserSpeech: nil)).count, 1)
    XCTAssertTrue(delivery.genioInterrupted(now: at(4)).isEmpty, "first loss: kept for a retry")
    let retry = delivery.tick(now: at(7), step: step, canSpeak: true, lastUserSpeech: at(4))
    guard case .send(_, retry: true)? = retry.first else { return XCTFail("expected a retry, got \(retry)") }
    let gaveUp = delivery.genioInterrupted(now: at(8))
    guard case .dropped(_, reason: .notHeard)? = gaveUp.first else { return XCTFail("expected given up, got \(gaveUp)") }
    XCTAssertTrue(delivery.isIdle)
  }

  func testAnsweringSomethingElseCountsAsNotHeard() {
    var delivery = RemarkDelivery()
    delivery.queue("Il cavo rosso non è collegato", kind: .mistake, step: step, now: at(0))
    _ = delivery.tick(now: at(3), step: step, canSpeak: true, lastUserSpeech: nil)
    XCTAssertTrue(delivery.genioFinishedTurn("Sì, il prossimo passo è chiudere lo sportello.", now: at(5)).isEmpty)
    XCTAssertEqual(delivery.pending.first?.sentAt, nil, "waiting to be sent again")
    XCTAssertEqual(delivery.pending.first?.attempts, 1)
  }

  func testNoAnswerInTimeIsSentAgain() {
    var delivery = RemarkDelivery()
    delivery.queue("Il cavo rosso non è collegato", kind: .mistake, step: step, now: at(0))
    _ = delivery.tick(now: at(3), step: step, canSpeak: true, lastUserSpeech: nil)
    let events = delivery.tick(now: at(14), step: step, canSpeak: true, lastUserSpeech: nil)
    guard case .send(_, retry: true)? = events.first else { return XCTFail("expected a retry, got \(events)") }
  }

  func testEmptyTurnsAreIgnored() {
    var delivery = RemarkDelivery()
    delivery.queue("Il cavo rosso non è collegato", kind: .mistake, step: step, now: at(0))
    _ = delivery.tick(now: at(3), step: step, canSpeak: true, lastUserSpeech: nil)
    XCTAssertTrue(delivery.genioFinishedTurn("  ", now: at(4)).isEmpty)
    XCTAssertNotNil(delivery.pending.first?.sentAt, "still in flight")
  }

  func testMistakeDroppedOnStepChangeHazardKept() {
    var delivery = RemarkDelivery()
    delivery.queue("Manca una rondella", kind: .mistake, step: step, now: at(0))
    delivery.queue("Il ferro è acceso", kind: .hazard, step: step, now: at(0))
    let next = RemarkDelivery.StepRef(index: 3, revision: 4)
    let events = delivery.tick(now: at(0.1), step: next, canSpeak: false, lastUserSpeech: nil)
    guard case .dropped(let remark, reason: .stepChanged)? = events.first else { return XCTFail("got \(events)") }
    XCTAssertEqual(remark.text, "Manca una rondella")
    XCTAssertEqual(delivery.pending.map(\.text), ["Il ferro è acceso"])
  }

  func testExpires() {
    var delivery = RemarkDelivery()
    delivery.queue("Manca una rondella", kind: .mistake, step: step, now: at(0))
    let events = delivery.tick(now: at(26), step: step, canSpeak: false, lastUserSpeech: nil)
    guard case .dropped(_, reason: .expired)? = events.first else { return XCTFail("got \(events)") }
  }

  func testHazardGoesFirstAndOneAtATime() {
    var delivery = RemarkDelivery()
    delivery.queue("Manca una rondella", kind: .mistake, step: step, now: at(0))
    delivery.queue("Il ferro è acceso", kind: .hazard, step: step, now: at(0))
    delivery.queue("il ferro è acceso", kind: .hazard, step: step, now: at(0))  // a repeat
    XCTAssertEqual(delivery.pending.count, 2)
    XCTAssertEqual(sent(delivery.tick(now: at(3), step: step, canSpeak: true, lastUserSpeech: nil)), ["Il ferro è acceso"])
    XCTAssertEqual(sent(delivery.tick(now: at(4), step: step, canSpeak: true, lastUserSpeech: nil)), [])
    _ = delivery.genioFinishedTurn("Attenzione, il ferro è acceso.", now: at(5))
    XCTAssertEqual(sent(delivery.tick(now: at(6), step: step, canSpeak: true, lastUserSpeech: nil)), ["Manca una rondella"])
  }

  func testExpectedRemarkIsWatchedWithoutBeingSent() {
    var delivery = RemarkDelivery()
    delivery.expect("Occhio alla lama", kind: .hazard, step: step, now: at(0))
    XCTAssertEqual(sent(delivery.tick(now: at(1), step: step, canSpeak: true, lastUserSpeech: nil)), [])
    _ = delivery.genioInterrupted(now: at(2))
    let events = delivery.tick(now: at(4), step: step, canSpeak: true, lastUserSpeech: at(2))
    guard case .send(_, retry: true)? = events.first else { return XCTFail("expected a retry, got \(events)") }
  }

  func testMatching() {
    XCTAssertTrue(RemarkDelivery.said("Attento, la pentola è molto calda", in: "Occhio alla pentola, scotta"))
    XCTAssertTrue(RemarkDelivery.said("Stringi la vite di sinistra", in: "Devi stringere bene quella vite"))
    XCTAssertTrue(RemarkDelivery.said("Careful, the blade is exposed", in: "Watch out, that blade is uncovered"))
    XCTAssertFalse(RemarkDelivery.said("Attento, la pentola è calda", in: "Attento, controlla bene"))
    XCTAssertFalse(RemarkDelivery.said("Il cavo rosso va nel morsetto L", in: "Passiamo al prossimo passo"))
    XCTAssertTrue(RemarkDelivery.said("Attento!", in: "Attento, fermati un attimo"), "no key words: any real sentence")
  }
}
