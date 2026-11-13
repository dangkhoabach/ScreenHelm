// The same executable also runs as the watcher that switches displays back
// on if ScreenHelm ends without doing so; that check comes before anything else.
ConnectionController.runWatcherIfRequested()
// `ScreenHelm display …` from a terminal talks to the running app and ends.
AutomationClient.runIfRequested()
ScreenHelmApp.main()
