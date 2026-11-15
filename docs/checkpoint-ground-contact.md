# Ground checkpoint contacts

Grounded checkpoints now accept an observed contact immediately when the
player's horizontal speed is at most **350 units/second**. This initial cap
includes a strafe-jump allowance above normal sprint speed. It is a practical
momentum limit, not a per-jump proof of reachability; a particular platform can
still benefit from carrying speed below the cap.

Above that cap, the existing **150 ms continuous grounded contact** is required.
Slowing to the cap or below allows the next observed contact to count. Vertical
velocity does not affect this comparison. Missing velocity information retains
the 150 ms rule. Leaving the area, leaving the ground, changing checkpoint, or
missing contact observations resets the pending landing.

The check uses the existing 50 ms server polling and actual checkpoint geometry.
An airborne overlap never satisfies a grounded checkpoint. A contact entirely
between polls can still be missed; native movement callbacks are unchanged.
Air checkpoints, checkpoint order, route/Any% handling, no-save areas, and the
editor's geometric selection rules retain their existing behavior.
