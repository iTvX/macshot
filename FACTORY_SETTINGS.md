# Default settings for this fork

New installations start with the maintained configuration in
`macshot/Services/FactorySettings.swift`. It is applied before application services
read preferences. It is a reviewed list of portable choices, not a copy of a local
UserDefaults plist.

| Setting | Shipped choice |
| --- | --- |
| Capture Area | Command-Shift-5 |
| Capture OCR & QR | Command-Shift-3 |
| Quick Capture | Option-S; alternative Command-Shift-4 |
| Capture Screen / Record Area shortcuts | Unassigned |
| History shortcut | Command-Shift-H |
| Other global shortcuts | Unassigned |
| Capture exclusions | Lotus (`com.itvx.lotus`) |
| OCR result | Copy to clipboard only |
| Capture sound | Off |
| Darkening outside the selected area | Off |
| Window snapping | On |
| Initial annotation tool / color | Pixelate / system red |
| Tools and output actions | All currently available tools and actions enabled |
| Screenshot filename | `Screenshot {date} at {time}` |
| Automatic update checks | On, using this fork's update feed |
| Launch at login | On where supported and allowed by macOS |

Other settings retain their existing built-in defaults. Overlay/editor shortcuts
are unchanged. macOS permissions still need to be granted on each machine, and
save folders resolve on the user's own machine.

Existing installations are recognized by their persisted app settings or startup
state and are not reseeded. Their explicitly saved values and implicit legacy
defaults are preserved. A local installation marker prevents later launches from
restoring settings a user cleared; neither it nor the pending login registration
flag can be exported or imported. A first-launch move to Applications preserves
the pending login registration. If macOS does not support or rejects registration,
the launch-at-login preference is turned off.

Each global shortcut's **Reset to default** button uses the shipped shortcut above,
including Quick Capture's alternative. The existing conflict checks still apply.
Settings imports retain their existing replace-portable semantics.

Regression tests cover fresh domains, sparse existing installations, repeated
launches, cleared settings, private-state exclusions, unique shortcut bindings,
and shortcut reset behavior. Update the profile and these tests together when
changing the maintained defaults.
