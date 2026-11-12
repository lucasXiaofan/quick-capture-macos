/// Every plugin the app ships, in menu and Settings order. Add new plugins here.
@MainActor
enum PluginRegistry {
    static func makeAll() -> [Plugin] {
        [
            RadialWheelPlugin(),
            ObsidianCapturePlugin(),
            TaskLogPlugin(),
            ReadAloudPlugin(),
            BrakePlugin(),
            AIChatPlugin(),
            NoseControlPlugin(),
            KeyboardMousePlugin(),
            VideoNotesPlugin(),
            TicketsPlugin(),
            SkillManagerPlugin(),
            MemoryMonitorPlugin(),
            StorageManagerPlugin(),
        ]
    }
}
