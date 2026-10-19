// CAVA emits 16 normalized bands at 30 Hz. Invalid frames are ignored.
function parse(line) {
  if (typeof line !== "string" || line.length > 96) return null
  var parts = line.trim().split(";")
  if (parts[parts.length - 1] === "") parts.pop()
  if (parts.length !== 16) return null
  var bands = []
  for (var i = 0; i < parts.length; i++) {
    if (!/^\d{1,3}$/.test(parts[i]) || Number(parts[i]) > 100) return null
    bands.push(Number(parts[i]) / 100)
  }
  return bands
}

// Fast attack and roughly 150 ms release, driven only by incoming audio.
function smooth(previous, incoming) {
  return incoming.map(function(value, index) {
    var last = previous.length === incoming.length ? previous[index] : 0
    last = isFinite(last) ? Math.max(0, Math.min(1, last)) : 0
    value = isFinite(value) ? Math.max(0, Math.min(1, value)) : 0
    var coefficient = value >= last ? 0.8 : 0.2
    var next = last + (value - last) * coefficient
    return next < 0.005 ? 0 : next
  })
}

if (typeof module !== "undefined") module.exports = { parse: parse, smooth: smooth }
