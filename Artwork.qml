import QtQuick
import Quickshell
import Quickshell.Io

// One request at a time. A completion from an older track is never published.
QtObject {
  id: root
  property string source: ""
  property string fallbackSource: ""
  property string url: ""
  property int generation: 0
  property int activeGeneration: -1
  property bool busy: false
  property bool triedFallback: false
  property string activeSource: ""
  property string result: ""
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("artwork.py").toString().replace(/^file:\/\//, ""))

  onSourceChanged: invalidate()
  onFallbackSourceChanged: invalidate()
  Component.onCompleted: invalidate()

  function invalidate() {
    generation++
    url = ""
    if (busy) worker.running = false
    else Qt.callLater(startLatest)
  }

  function startLatest() {
    if (busy || !source) return
    activeGeneration = generation
    triedFallback = false
    start(source)
  }

  function start(request) {
    if (busy) return
    busy = true
    activeSource = request
    result = ""
    worker.command = ["python3", helperPath]
    worker.stdinEnabled = true
    worker.running = true
    deadline.restart()
  }

  function finish(exitCode) {
    if (!busy) return
    busy = false
    deadline.stop()
    forceStop.stop()
    if (activeGeneration !== generation) {
      Qt.callLater(startLatest)
    } else if (exitCode === 0 && result) {
      url = result
    } else if (!triedFallback && fallbackSource && fallbackSource !== activeSource) {
      triedFallback = true
      Qt.callLater(function() {
        if (root.activeGeneration === root.generation) root.start(root.fallbackSource)
      })
    }
  }

  property Timer deadline: Timer {
    id: deadline
    interval: 15000
    onTriggered: {
      if (worker.running) {
        worker.signal(15)
        forceStop.restart()
      } else root.finish(1)
    }
  }

  property Timer forceStop: Timer {
    id: forceStop
    interval: 2000
    onTriggered: {
      if (worker.running) worker.signal(9)
      else root.finish(1)
    }
  }

  property Process worker: Process {
    id: worker
    onStarted: worker.write(JSON.stringify({ source: root.activeSource }) + "\n")
    stdout: SplitParser {
      onRead: function(line) {
        if (line.length > 8192) return
        try {
          var reply = JSON.parse(line)
          if (typeof reply.url === "string" && /^file:\/\/\/.*\/[a-f0-9]{64}\.(png|jpg|gif|webp|bmp)$/.test(reply.url))
            root.result = reply.url
        } catch (error) { root.result = "" }
      }
    }
    onExited: function(exitCode) { root.finish(exitCode) }
    onRunningChanged: if (!running) Qt.callLater(function() {
      if (!worker.running) root.finish(1)
    })
  }
}
