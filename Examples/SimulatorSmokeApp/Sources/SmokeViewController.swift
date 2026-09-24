import UIKit

@objc(SmokeViewController)
final class SmokeViewController: UIViewController {
    private let statusLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        title = "agentInjectionIII"

        statusLabel.font = .monospacedSystemFont(
            ofSize: 34,
            weight: .bold
        )
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier =
            "injection-status"

        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        subtitleLabel.text =
            SmokeObjCHelper.podBackedSubtitle()

        let stack = UIStackView(
            arrangedSubviews: [
                statusLabel,
                subtitleLabel
            ]
        )
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            stack.centerYAnchor.constraint(
                equalTo: view.centerYAnchor
            ),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo:
                    view.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo:
                    view.trailingAnchor,
                constant: -24
            )
        ])

        refreshSmokeState()

        timer = Timer.scheduledTimer(
            withTimeInterval: 0.20,
            repeats: true
        ) { [weak self] _ in
            self?.refreshSmokeState()
        }
    }

    deinit {
        timer?.invalidate()
    }

    @objc dynamic func smokeMessage() -> String {
        "BEFORE"
    }

    private func refreshSmokeState() {
        let message = smokeMessage()
        statusLabel.text = message

        guard let documents = FileManager.default
            .urls(
                for: .documentDirectory,
                in: .userDomainMask
            )
            .first else {
            return
        }

        let marker = documents
            .appendingPathComponent(
                "agentInjection-smoke.txt"
            )

        try? message.write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
    }
}
