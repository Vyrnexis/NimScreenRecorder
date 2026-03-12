import nigui

import ui

when isMainModule:
  # Initialize NiGui first, then construct and show the main recorder window.
  app.init()
  let screenRecorder = newRecorderUi()
  screenRecorder.window.show()
  app.run()
