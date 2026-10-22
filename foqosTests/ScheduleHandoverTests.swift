import DeviceActivity
import FamilyControls
import XCTest

@testable import foqos

final class ScheduleHandoverTests: XCTestCase {
  let firstId = UUID()
  let secondId = UUID()

  override func setUp() {
    super.setUp()
    SharedData.flushActiveSession()
    SharedData.setSnapshot(snapshot(firstId), for: firstId.uuidString)
    SharedData.setSnapshot(snapshot(secondId), for: secondId.uuidString)
  }

  override func tearDown() {
    SharedData.flushActiveSession()
    SharedData.removeSnapshot(for: firstId.uuidString)
    SharedData.removeSnapshot(for: secondId.uuidString)
    super.tearDown()
  }

  private func snapshot(_ id: UUID) -> SharedData.ProfileSnapshot {
    var schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0)
    schedule.updatedAt = Date().addingTimeInterval(-3600)
    return SharedData.ProfileSnapshot(
      id: id, name: "Profile", selectedActivity: FamilyActivitySelection(),
      createdAt: Date(), updatedAt: Date(), blockingStrategyId: nil, strategyData: nil, order: 0,
      enableLiveActivity: false, reminderTimeInSeconds: nil, customReminderMessage: nil,
      enableBreaks: false, enableStrictMode: false, enableAllowMode: false,
      enableAllowModeDomains: false, enableSafariBlocking: false, domains: nil,
      schedule: schedule)
  }

  // The first profile's schedule ends at the same minute the second one's starts
  private func handOver(concurrently: Bool) {
    let first = DeviceActivityName(rawValue: firstId.uuidString)
    let second = DeviceActivityName(rawValue: secondId.uuidString)
    TimerActivityUtil.startTimerActivity(for: first)
    let end = { TimerActivityUtil.stopTimerActivity(for: first) }
    let start = { TimerActivityUtil.startTimerActivity(for: second) }

    if concurrently {
      DispatchQueue.concurrentPerform(iterations: 2) { $0 == 0 ? end() : start() }
    } else {
      end()
      start()
    }
  }

  func testSecondProfileStartsAfterFirstEnds() {
    handOver(concurrently: false)
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, secondId)
  }

  func testSecondProfileStartsWhenCallbacksArriveTogether() {
    for _ in 0..<100 {
      setUp()
      handOver(concurrently: true)
      XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, secondId)
    }
  }
}
