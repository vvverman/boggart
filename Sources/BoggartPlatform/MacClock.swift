import Foundation
import Darwin
import BoggartCore

public enum MacClock {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()
    public static var continuous: TimeInterval {
        Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
    public static var reading: ClockReading { .init(continuous, wall: Date()) }
}
