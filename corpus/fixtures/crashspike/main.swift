import Foundation

struct Order {
    let id: Int
    var discount: Double?
}

func applyDiscount(_ order: Order) -> Double {
    // deliberate crash: force-unwrap of nil → EXC_BREAKPOINT (SIGTRAP)
    return order.discount! * 100.0
}

func processOrder(_ order: Order) -> Double {
    return applyDiscount(order)
}

func run() {
    let order = Order(id: 42, discount: nil)
    let value = processOrder(order)
    print("discount value: \(value)")
}

run()
