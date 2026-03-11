import nigui

import ui

proc runApp*() =
  app.init()
  let screenRecorder = newRecorderUi()
  screenRecorder.window.show()
  app.run()
