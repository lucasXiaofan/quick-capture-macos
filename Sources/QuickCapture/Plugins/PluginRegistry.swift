/// Every plugin the app ships, in menu and Settings order. Add new plugins here.
@MainActor
enum PluginRegistry {
    static func makeAll() -> [Plugin] {
        [
            ObsidianCapturePlugin(),
            TaskLogPlugin(),
            ReadAloudPlugin(),
            AIChatPlugin(),
            NoseControlPlugin(),
            KeyboardMousePlugin(),
            VideoNotesPlugin(),
            SkillManagerPlugin(),
        ]
            MemoryMonitorPlugin(),
    }
}
