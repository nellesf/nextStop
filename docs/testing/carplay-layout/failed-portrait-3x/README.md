# Incomplete portrait capture diagnostics

These selected original diagnostics explain two capture failures on
900 × 1200 @3x. They are **not completed layout capture sets** and have no passing
hosted-test claim. Each directory preserves its actual run, source metadata,
verified display configuration, and byte hashes in `diagnostic-source.json`.

- [34959786544](34959786544/diagnostic-external-0-9.png): the real profile screen
  was visible, but “Fahrt wählen” was ellipsized. Requiring its full text as a
  readiness condition prevented the audit from capturing the defect. Short
  `Profile` + `Leipzig` anchors fix that gate while retaining full expected text.
- [34962890365](34962890365/diagnostic-external-0-11.png): the nextStop icon was
  [targeted by a native click](34962890365/diagnostic-host-after-click-1.png),
  but later frames still showed the CarPlay home screen. A dispatched click
  must not count as readiness. The bounded activation correction requires two
  rendered profile frames and permits one additional click only when fresh
  frames still unambiguously show home.

The evidence supports these observed failure stages. It does not establish why
the native first click was ineffective or guarantee that another click succeeds.
See the [operations guide](../../../operations/simulator-screenshots.md) for the
current tested procedure and retry limits.
