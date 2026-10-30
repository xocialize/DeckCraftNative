// DCApp — the app's areas, each installing its UI commands, request handlers and control methods into the
// `AppController`. One line per area: an area's code lives in its own folder and is owned by one person (or
// session) at a time, so parallel work never edits the same file.
@MainActor
enum Features {
    static func installAll(_ app: AppController) {
        CanvasFeature.install(app)
        InspectorFeature.install(app)
        RibbonFeature.install(app)
        DialogsFeature.install(app)
        ShowFeature.install(app)
        ViewsFeature.install(app)
        AutomationFeature.install(app)
        UpdatesFeature.install(app)
        IntentsFeature.install(app)
        SpotlightFeature.install(app)
        // After Show: the start window's `ui.screenshot {window: "start"}` hands every other window to Show's.
        StartFeature.install(app)
    }
}
