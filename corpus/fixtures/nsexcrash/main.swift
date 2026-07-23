import Foundation

func throwingHelper() {
    NSException(
        name: .rangeException,
        reason: "crashdx fixture: index 42 beyond bounds",
        userInfo: nil
    ).raise()
}

func doWork() {
    throwingHelper()
}

doWork()
