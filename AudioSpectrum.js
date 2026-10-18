// Envelope at CAVA's 30 Hz: fast attack, roughly 150 ms release.
// Decay only follows incoming audio frames; there is no synthetic motion.
function smooth(previous, incoming) {
  return incoming.map(function(value, index) {
    var last = previous.length === incoming.length ? previous[index] : 0
    var coefficient = value >= last ? 0.8 : 0.2
    var next = last + (value - last) * coefficient
    return next < 0.005 ? 0 : next
  })
}

if (typeof module !== "undefined") module.exports = { smooth: smooth }
