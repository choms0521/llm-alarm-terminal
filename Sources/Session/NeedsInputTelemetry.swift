import Foundation
import Combine

/// needsInput 트리거의 월 카운터를 보관한다. 월 trigger count < 1 이 1회 발생
/// 하면 policy v1 의 카피가 더 이상 매칭되지 않을 가능성(claude CLI 출력 변경
/// 의심) 을 시사한다.
@MainActor
public final class NeedsInputTelemetry: ObservableObject {
    @Published public private(set) var triggerCountThisMonth: Int = 0
    @Published public private(set) var lastTriggeredAt: Date?

    private var monthAnchor: DateComponents?
    private let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    /// 월 카운터 reset 조건: 현재 month-of-year 가 마지막 record 시점의 그것과
    /// 다르면 0 으로 reset 후 ++. 같은 달이면 그대로 ++.
    public func record(now: Date = Date()) {
        let comps = calendar.dateComponents([.year, .month], from: now)
        if monthAnchor != comps {
            monthAnchor = comps
            triggerCountThisMonth = 0
        }
        triggerCountThisMonth += 1
        lastTriggeredAt = now
    }
}
