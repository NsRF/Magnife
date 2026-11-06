import Darwin

/// CPU time, so a timing check can say whether a slow value was the app's
/// work or time spent waiting for a core. Wall time minus CPU time on the
/// thread that did the work is time that thread was not running: blocked,
/// or runnable but not scheduled because the machine was busy.
enum CPUTime {
    /// CPU time of the calling thread, in milliseconds.
    static var thread: Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }

    /// CPU time of every thread of this process, user and system, in milliseconds.
    static var process: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func ms(_ time: timeval) -> Double { Double(time.tv_sec) * 1_000 + Double(time.tv_usec) / 1_000 }
        return ms(usage.ru_utime) + ms(usage.ru_stime)
    }
}
