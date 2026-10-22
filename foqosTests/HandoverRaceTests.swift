import DeviceActivity
import FamilyControls
import ManagedSettings
import XCTest

@testable import foqos

/// Two scheduled profiles hand over at the same minute: Work ends 16:00, Home starts 16:00.
/// iOS delivers Work's intervalDidEnd and Home's intervalDidStart to the monitor extension.
/// These tests drive the real entry point, TimerActivityUtil, the way the extension does.
final class HandoverRaceTests: XCTestCase {
  let workId = UUID()
  let homeId = UUID()

  override func setUp() {
    super.setUp()
    SharedData.flushActiveSession()
    SharedData.flushCompletedSessionsForSchedular()
    SoftUnblockGrantStore.clearAll()
    SharedData.setSnapshot(profile(workId, "Work", 7, 30, 16, 0), for: workId.uuidString)
    SharedData.setSnapshot(
      profile(homeId, "Home", 16, 0, 22, 0, opens: 6, minutes: 20), for: homeId.uuidString)
  }

  override func tearDown() {
    SharedData.flushActiveSession()
    SharedData.flushCompletedSessionsForSchedular()
    SoftUnblockGrantStore.clearAll()
    SharedData.removeSnapshot(for: workId.uuidString)
    SharedData.removeSnapshot(for: homeId.uuidString)
    super.tearDown()
  }

  private func profile(_ id: UUID, _ name: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int,
    opens: Int = 4, minutes: Int = 15
  ) -> SharedData.ProfileSnapshot
  {
    var schedule = BlockedProfileSchedule(
      days: Weekday.allCases, startHour: sh, startMinute: sm, endHour: eh, endMinute: em)
    schedule.updatedAt = Date().addingTimeInterval(-24 * 3600)  // saved last night
    let strategy = SoftUnblockStrategyData.encode(
      SoftUnblockStrategyData(
        accessDurationInMinutes: minutes, maximumUnblockCount: opens, allowanceResetIntervalInHours: nil))
    return SharedData.ProfileSnapshot(
      id: id, name: name, selectedActivity: FamilyActivitySelection(),
      createdAt: Date(), updatedAt: Date(),
      blockingStrategyId: SoftUnblockSessionLifecycleHandler.nfcStrategyId,
      strategyData: strategy, order: 0, enableLiveActivity: false,
      reminderTimeInSeconds: nil, customReminderMessage: nil, enableBreaks: false,
      enableStrictMode: true, enableAllowMode: false, enableAllowModeDomains: false,
      enableSafariBlocking: true, domains: nil, schedule: schedule)
  }

  private func activity(_ id: UUID) -> DeviceActivityName { DeviceActivityName(rawValue: id.uuidString) }
  private func workEnds() { TimerActivityUtil.stopTimerActivity(for: activity(workId)) }
  private func homeStarts() { TimerActivityUtil.startTimerActivity(for: activity(homeId)) }

  private func startWork() {
    TimerActivityUtil.startTimerActivity(for: activity(workId))
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, workId)
  }

  /// An opaque token decoded from bytes, standing in for X; the code only stores and compares it.
  private var fakeToken: ApplicationToken {
    let json = Data(#"{"data":"AAECAwQFBgcICQ=="}"#.utf8)
    return try! JSONDecoder().decode(ApplicationToken.self, from: json)
  }

  /// Uses one open the way the shield's "Open for 15m" button does.
  /// `startedMinutesAgo: 15` makes an open that has just run out.
  @discardableResult
  private func useOpen(startedMinutesAgo: Double = 5) -> SoftUnblockGrant {
    let session = SoftUnblockGrantStore.activeSession!
    let created = Date().addingTimeInterval(-startedMinutesAgo * 60)
    let grant = SoftUnblockGrant(
      id: UUID(), sessionId: session.sessionId, profileId: session.profileId,
      resource: .application(fakeToken), createdAt: created,
      expiresAt: created.addingTimeInterval(15 * 60))
    XCTAssertTrue(SoftUnblockGrantStore.issue(grant))
    return grant
  }

  /// The open's own monitor ending: at its expiry, or when Home's start calls stopMonitoring on it
  /// (Apple documents that stopMonitoring on an ongoing interval delivers intervalDidEnd).
  private func openEnds(_ g: SoftUnblockGrant) {
    TimerActivityUtil.stopTimerActivity(
      for: DeviceActivityName(
        rawValue: "\(SoftUnblockGrantScheduler.activityId):\(g.profileId.uuidString)|\(g.sessionId)|\(g.id.uuidString)"))
  }

  /// What Alex should see after 4:00: Home running, Home's six opens untouched, X not unblocked.
  private func assertHomeClean(_ file: StaticString = #filePath, _ line: UInt = #line) {
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId, file: file, line: line)
    XCTAssertEqual(SoftUnblockGrantStore.activeSession?.profileId, homeId, file: file, line: line)
    XCTAssertEqual(SoftUnblockGrantStore.activeSession?.remainingUnblockCount, 6, file: file, line: line)
    XCTAssertTrue(SoftUnblockGrantStore.activeGrants(for: homeId).isEmpty, file: file, line: line)
  }

  // MARK: one after the other

  func testEndThenStart() {
    startWork()
    workEnds()
    homeStarts()
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId)
  }

  func testStartThenEnd() {
    startWork()
    homeStarts()
    workEnds()
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId)
  }

  func testStartThenEndWithAnOpenRunning() {
    startWork()
    useOpen()
    homeStarts()
    workEnds()
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId)
    XCTAssertEqual(SoftUnblockGrantStore.activeSession?.profileId, homeId)
  }

  func testEndThenStartWithAnOpenRunning() {
    startWork()
    useOpen()
    workEnds()
    homeStarts()
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId)
    XCTAssertEqual(SoftUnblockGrantStore.activeSession?.profileId, homeId)
  }

  // MARK: at the same moment

  /// Runs Work's end and Home's start on two threads released together, many times.
  /// Returns how many trials ended with no session at all, and how many with Work still active.
  private func race(trials: Int, withOpen: Bool) -> (none: Int, work: Int, home: Int) {
    race(trials: trials) {
      guard withOpen else { return [self.workEnds, self.homeStarts] }
      let g = self.useOpen()
      return [self.workEnds, self.homeStarts, { self.openEnds(g) }]
    }
  }

  /// `jobs` runs after Work has started and returns the callbacks to fire together.
  private func race(trials: Int, jobs: () -> [() -> Void]) -> (none: Int, work: Int, home: Int) {
    var none = 0
    var work = 0
    var home = 0
    for _ in 0..<trials {
      setUp()
      startWork()
      let fired = jobs()
      let gate = DispatchGroup()
      let go = DispatchSemaphore(value: 0)
      for job in fired {
        gate.enter()
        Thread.detachNewThread {
          go.wait()
          job()
          gate.leave()
        }
      }
      for _ in fired { go.signal() }
      if gate.wait(timeout: .now() + 5) == .timedOut { print("HANDOVER STALLED: callbacks did not finish within 5 seconds"); XCTFail("callbacks deadlocked"); return (none, work, home) }
      switch SharedData.getActiveSharedSession()?.blockedProfileId {
      case nil: none += 1
      case workId: work += 1
      default: home += 1
      }
    }
    return (none, work, home)
  }

  func testSimultaneousHandover() {
    let r = race(trials: 300, withOpen: false)
    print("RACE no-open: none=\(r.none) work=\(r.work) home=\(r.home) of 300")
    XCTAssertEqual(r.none + r.work, 0, "handover lost: none=\(r.none) work=\(r.work)")
  }

  func testSimultaneousHandoverWithAnOpenRunning() {
    let r = race(trials: 300, withOpen: true)
    print("RACE with-open: none=\(r.none) work=\(r.work) home=\(r.home) of 300")
    XCTAssertEqual(r.none + r.work, 0, "handover lost: none=\(r.none) work=\(r.work)")
  }

  // MARK: Alex's case, 21 Oct: an open on X running when Work hands over to Home

  func testOpenRunning_HomeStarts_ThenOpensMonitorEnds_ThenWorkEnds() {
    startWork()
    let g = useOpen()
    homeStarts()
    openEnds(g)
    workEnds()
    assertHomeClean()
  }

  func testOpenRunning_WorkEnds_ThenHomeStarts_ThenOpenExpires() {
    startWork()
    let g = useOpen(startedMinutesAgo: 14)
    workEnds()
    homeStarts()
    openEnds(SoftUnblockGrant(
      id: g.id, sessionId: g.sessionId, profileId: g.profileId, resource: g.resource,
      createdAt: g.createdAt.addingTimeInterval(-60), expiresAt: Date().addingTimeInterval(-1)))
    assertHomeClean()
  }

  func testOpenExpiringAtTheSameMinute() {
    startWork()
    let g = useOpen(startedMinutesAgo: 15)  // ran out right at 4:00
    homeStarts()
    openEnds(g)
    workEnds()
    assertHomeClean()
  }

  /// All three at once: Work's end, Home's start, and the open's monitor ending.
  func testSimultaneousHandoverAndOpenEnding() {
    let r = race(trials: 300, withOpen: true)
    print("RACE three-way: none=\(r.none) work=\(r.work) home=\(r.home) of 300")
    XCTAssertEqual(r.none + r.work, 0, "handover lost: none=\(r.none) work=\(r.work)")
  }

  /// The overlap workaround: Home's start and the open ending can still collide at 4:00,
  /// but Work's end comes five minutes later on its own.
  func testOverlapFixWithOpenEndingAtTheSameMoment() {
    var dirty = 0
    let r = race(trials: 300) {
      let g = self.useOpen()
      return [self.homeStarts, { self.openEnds(g) }]
    }
    // finish each trial's 4:05 end is checked separately below; here Home must hold after 4:00
    print("RACE overlap 4:00: none=\(r.none) work=\(r.work) home=\(r.home) of 300")
    XCTAssertEqual(r.none + r.work, 0)
    for _ in 0..<50 {
      setUp(); startWork(); let g = useOpen()
      homeStarts(); openEnds(g); workEnds()
      if SoftUnblockGrantStore.activeSession?.remainingUnblockCount != 6
        || !SoftUnblockGrantStore.activeGrants(for: homeId).isEmpty
        || SharedData.getActiveSharedSession()?.blockedProfileId != homeId { dirty += 1 }
    }
    XCTAssertEqual(dirty, 0)
  }

  // MARK: the overlap fix: Work ends 16:05, five minutes after Home starts

  func testOverlapFix() {
    startWork()
    useOpen()
    homeStarts()  // 16:00
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId)
    workEnds()  // 16:05, a separate callback five minutes later
    XCTAssertEqual(SharedData.getActiveSharedSession()?.blockedProfileId, homeId)
  }
}
