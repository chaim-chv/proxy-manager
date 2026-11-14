import CoreGraphics
import Foundation

// Moves the pointer off a captured window so hover states (chart readouts,
// tooltips) do not leak into marketing screenshots. Used by
// capture-screenshots.sh before each `screencapture`.
CGWarpMouseCursorPosition(CGPoint(x: 4, y: 4))
CGAssociateMouseAndMouseCursorPosition(1)
