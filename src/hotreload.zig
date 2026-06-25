const std = @import("std");

var reload_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn init() void {
    reload_flag.store(false, .monotonic);
}

pub fn notify() void {
    reload_flag.store(true, .release);
}

pub fn check() bool {
    return reload_flag.rmw(.Xchg, false, .acq_rel);
}
