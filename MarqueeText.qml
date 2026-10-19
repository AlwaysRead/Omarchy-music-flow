import QtQuick

// Read long metadata without expanding the popup or clipping adjacent controls.
Item {
  id: root
  property alias text: label.text
  property alias font: label.font
  property alias color: label.color
  property bool animationEnabled: true
  readonly property real overflow: Math.max(0, label.implicitWidth - width)
  readonly property bool scrolling: animationEnabled && visible && width > 0 && overflow > 0
  implicitWidth: label.implicitWidth
  implicitHeight: label.implicitHeight
  clip: true

  function resetScroll() {
    motion.stop()
    label.x = 0
    if (scrolling) motion.start()
  }

  onScrollingChanged: Qt.callLater(resetScroll)
  onOverflowChanged: Qt.callLater(resetScroll)

  Text {
    id: label
    textFormat: Text.PlainText
    onTextChanged: Qt.callLater(root.resetScroll)
  }

  SequentialAnimation {
    id: motion
    loops: Animation.Infinite
    onStopped: label.x = 0
    PauseAnimation { duration: 1800 }
    NumberAnimation {
      target: label
      property: "x"
      from: 0
      to: -root.overflow
      duration: Math.max(1800, root.overflow * 35)
      easing.type: Easing.Linear
    }
    PauseAnimation { duration: 1800 }
    NumberAnimation {
      target: label
      property: "x"
      from: -root.overflow
      to: 0
      duration: Math.max(1800, root.overflow * 35)
      easing.type: Easing.Linear
    }
  }
}
