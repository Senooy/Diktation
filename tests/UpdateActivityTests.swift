@main
enum UpdateActivityTests {
    static func main() {
        // Every kind of active work must prevent installation, including overlaps
        // while native capture hands its final audio to the Rust core.
        for mask in 0..<64 {
            let activity = UpdateActivity(busy: mask & 1 != 0, recording: mask & 2 != 0,
                processing: mask & 4 != 0, analysis: mask & 8 != 0,
                preparing: mask & 16 != 0, stopping: mask & 32 != 0)
            precondition(activity.permitsInstallation == (mask == 0), "Unsafe update during activity \(mask)")
        }
        print("Update activity: all 64 combinations passed")
    }
}
