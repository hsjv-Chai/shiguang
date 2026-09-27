import Foundation

// A portable assertion runner: Apple's Command Line Tools do not ship XCTest.
class XCTestCase { func setUpWithError() throws {}; func tearDownWithError() throws {} }
var failures: [String] = []
func fail(_ message: String, _ file: StaticString, _ line: UInt) { let text = "\(file):\(line): \(message)"; failures.append(text); print("FAIL: " + text) }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { fail("\(x) != \(y) \(message)", file, line) } } catch { fail(error.localizedDescription, file, line) }
}
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { if abs(a - b) > accuracy { fail("\(a) != \(b)", file, line) } }
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) { do { if try !a() { fail("Expected true", file, line) } } catch { fail(error.localizedDescription, file, line) } }
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) { do { if try a() { fail("Expected false", file, line) } } catch { fail(error.localizedDescription, file, line) } }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) { do { if try a() != nil { fail("Expected nil", file, line) } } catch { fail(error.localizedDescription, file, line) } }
func XCTAssertNotNil<T>(_ a: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) { do { if try a() == nil { fail("Expected value", file, line) } } catch { fail(error.localizedDescription, file, line) } }
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try a(); fail("Expected error", file, line) } catch {} }
func XCTUnwrap<T>(_ a: @autoclosure () throws -> T?) throws -> T { guard let value = try a() else { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required value"]) }; return value }
let tests = PhotoCoreTests()
let cases: [(String, () throws -> Void)] = [
    ("日期边界与时区", tests.testDateBoundariesAndTimezone),
    ("普通照片格式写入及逐字节撤销", tests.testAllRegularFormatsWriteAndByteExactUndo),
    ("RAW 不变及新 XMP 撤销", tests.testRAWStaysUnchangedAndNewSidecarUndoDeletesIt),
    ("保留既有 XMP 信息并恢复", tests.testExistingXMPPreservesRatingAndRestoresBytes),
    ("重名归档与配套文件撤销", tests.testArchiveCollisionSidecarAndUndo),
    ("预览后源文件变化", tests.testSourceChangedAfterPreviewCannotWrite),
    ("目标冲突不覆盖", tests.testDestinationAppearedAfterPreviewCannotOverwrite),
    ("撤销拒绝外部修改", tests.testUndoRejectsExternalChanges),
    ("备份失败不改原片", tests.testBackupFailureLeavesOriginalUntouched),
    ("Canon 配对扫描和旧索引合并", tests.testPairScanAndMigration),
    ("Canon 配对迟到缺失和恢复", tests.testPairLateArrivalMissingAndRecovery),
    ("Canon 配对范围和批次边界", tests.testPairScopesAndChunkBoundaries),
    ("Canon 真正的配套歧义", tests.testPairAmbiguity),
    ("Canon 时间优先级和 GPS", tests.testPairCapturePriorityAndGPS),
    ("Canon 三种校时及逐字节撤销", tests.testPairTimeAndExactUndo),
    ("Canon 既有 XMP 与零偏移同步", tests.testPairExistingXMPAndNoOpSynchronization),
    ("Canon 整组归档冲突重试和撤销", tests.testPairArchiveCollisionRetryAndUndo),
    ("Canon 校时恢复和只读成员校验", tests.testPairPreflightAndPartialTimeResume),
    ("Canon 旧历史拆分与重新合并", tests.testPairLegacyHistoryReconciliation),
    ("Canon 部分校时写入恢复和取消", tests.testPairPartialWriteResumeAndCancel),
    ("Canon 整组操作前检查", tests.testPairWholeGroupPreflight),
    ("Canon 旧 JPG 校时历史撤销", tests.testPairLegacyJPGUndo),
    ("跨盘流程中断后重试", tests.testCopyMoveFailureBeforeDeleteKeepsSourceAndCanResume),
    ("取消和恢复不重复偏移", tests.testCancelAndResumeDoesNotDoubleShift),
    ("提交后崩溃恢复", tests.testCrashAfterTimeCommitDoesNotShiftAgain),
    ("缺失拍摄时间", tests.testMissingTimeUsesUnknownAndNeverFileModificationDate),
    ("GPS 正负与手动地点持久化", tests.testSouthernWesternGPSAndManualPlacePersistence),
    ("一万张扫描和取消恢复", tests.testTenThousandScanAndCancellation)
]
let extra: [(String, () throws -> Void)] = [
    ("校时优化：批量预览与大 RAW", tests.testTimePreviewBatchesAndLargeRAW),
    ("校时优化：取消运行中的元数据进程", tests.testTimePreviewCancelsRunningMetadataProcess),
    ("校时优化：文件错误隔离与预览变化", tests.testTimePreviewIsolationAndChanges),
    ("校时优化：读取次数与小数秒", tests.testTimeExecutionReadsAndFractions),
    ("校时优化：提交和撤销故障恢复", tests.testTimeFaultWindowsAndRecovery),
    ("校时优化：写入失败取消和 XMP 冲突", tests.testTimeFailuresCancelAndNewXMPConflict),
    ("校时优化：整组准备失败和写入取消", tests.testTimePreparationFailureAndWriteCancellation),
    ("校时优化：等长修改与文件替换", tests.testTimeEqualLengthModificationAndReplacement),
    ("校时优化：旧日志和损坏备份", tests.testTimeLegacyJournalAndCorruptDurableBackup),
    ("归档优化：读取次数与元数据", tests.testArchiveReadCountsAndMetadata),
    ("归档优化：提交故障恢复", tests.testArchiveFaultWindows),
    ("归档优化：复制损坏与整组准备", tests.testArchiveCopyCorruptionAndGroupPreparation),
    ("归档优化：写入失败取消与清理", tests.testArchiveWriteFailureCancellationAndCleanup),
    ("归档优化：外部修改与提交冲突", tests.testArchiveExternalChangesAndCommitCollision),
    ("归档优化：撤销故障恢复", tests.testArchiveUndoFaultWindows),
    ("归档优化：删除保护与跨盘回退", tests.testArchiveDeleteGuardsFallbackAndUndoDiscard),
    ("归档优化：恢复身份与旧日志兼容", tests.testArchiveRecoveryRejectsReplacedTargetAndLegacyJSON),
    ("归档优化：真实数据计时", tests.testArchiveRealDataBenchmark),
    ("归档性能：80GB 批量快速预览", tests.testLargeArchivePreviewIsMetadataOnly),
    ("归档性能：延迟校验变更检测与取消", tests.testDeferredArchiveDetectsChangesAndCancels),
    ("归档性能：执行不重读元数据", tests.testArchiveFastPathAvoidsMetadataReread),
    ("跨盘删除前失败直接撤销", tests.testUndoCopyMoveWithBothFilesAfterFailure),
    ("撤销提交途中重启", tests.testUndoRestartAfterRestoredCopyBeforeDestinationDeletion),
    ("拒绝直接扫描系统照片图库", tests.testPhotosLibraryIsNotTraversed),
    ("损坏备份阻止重试写入", tests.testCorruptBackupPreventsRetryMutation)
]
setbuf(stdout, nil)
let start = Date()
for (name, test) in cases + extra {
    if let filter = CommandLine.arguments.dropFirst().first, !name.contains(filter) { continue }
    let count = failures.count
    do { try tests.setUpWithError(); try test() } catch { fail("\(name): \(error)", #filePath, #line) }
    do { try tests.tearDownWithError() } catch { fail("cleanup: \(error)", #filePath, #line) }
    print("\(count == failures.count ? "PASS" : "FAIL") \(name)")
}
print("RESULT: \(failures.count) failures; \(Date().timeIntervalSince(start)) seconds")
exit(failures.isEmpty ? 0 : 1)
