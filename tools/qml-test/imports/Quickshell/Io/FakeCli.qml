pragma Singleton
import QtQuick

// The scripted engine behind the fake Process. A test queues expected invocations; each entry
// is { argv: [...], reply: { exitCode, stdout, stderr } | { hang: true } | { unavailable: true },
// times: n }. "*" in argv matches any one argument. Invocations are answered by the first
// queued entry that matches; anything else is recorded as unexpected and answered with a
// refusal, so a test can assert both what was run and that nothing else was.
QtObject {
  id: fake
  property var queue: []
  property var calls: []
  property var unexpected: []

  function reset(entries) {
    fake.queue = (entries || []).map(function(e) { return { argv: e.argv, reply: e.reply, times: e.times || 1 } })
    fake.calls = []
    fake.unexpected = []
  }

  function matches(pattern, argv) {
    if (pattern.length !== argv.length) return false
    for (var i = 0; i < pattern.length; i++) if (pattern[i] !== "*" && pattern[i] !== argv[i]) return false
    return true
  }

  function take(argv) {
    var list = fake.calls.slice(); list.push(argv.slice()); fake.calls = list
    for (var i = 0; i < fake.queue.length; i++) {
      var entry = fake.queue[i]
      if (fake.matches(entry.argv, argv)) {
        if (entry.times > 1) entry.times -= 1
        else { var rest = fake.queue.slice(); rest.splice(i, 1); fake.queue = rest }
        return entry.reply
      }
    }
    var odd = fake.unexpected.slice(); odd.push(argv.join(" ")); fake.unexpected = odd
    return { exitCode: 1, stdout: "", stderr: "worldline: FAKE_UNEXPECTED_CALL: " + argv.join(" ") + "\n" }
  }

  function ran(prefix) {
    return fake.calls.filter(function(argv) { return argv.slice(0, prefix.length).join(" ") === prefix.join(" ") }).length
  }
}
