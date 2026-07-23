import Foundation

// Deliberate real null-pointer dereference: unsafeBitCast constructs a *non-optional*
// UnsafeMutablePointer<Int> with address 0, bypassing Swift's nil-optional-pointer
// precondition trap (which would otherwise produce EXC_BREAKPOINT, not a real SIGSEGV).
// Dereferencing it triggers a genuine kernel KERN_INVALID_ADDRESS fault at 0x0.
func readThroughNullPointer() -> Int {
    let ptr = unsafeBitCast(0 as Int, to: UnsafeMutablePointer<Int>.self)
    return ptr.pointee
}

func run() {
    print("about to crash: \(readThroughNullPointer())")
}

run()
