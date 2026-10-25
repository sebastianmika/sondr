import Metal

// Standard CI machines may not expose a Metal device. Keep CPU validation and
// demo resource tests running there, and report GPU-dependent tests as skipped.
let metalIsAvailable = MTLCreateSystemDefaultDevice() != nil
