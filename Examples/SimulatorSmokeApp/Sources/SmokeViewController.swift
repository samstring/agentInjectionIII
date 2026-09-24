import UIKit

@objc(SmokeViewController)
final class SmokeViewController: UIViewController {
    private let statusLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let touchButton = UIButton(type: .system)
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

        touchButton.setTitle(
            "Replay touch",
            for: .normal
        )
        touchButton.titleLabel?.font =
            .systemFont(
                ofSize: 18,
                weight: .semibold
            )
        touchButton.accessibilityIdentifier =
            "touch-replay-button"
        touchButton.addTarget(
            self,
            action: #selector(didReplayTouch),
            for: .touchUpInside
        )

        let stack = UIStackView(
            arrangedSubviews: [
                statusLabel,
                subtitleLabel,
                touchButton
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
            ),
            touchButton.heightAnchor.constraint(
                equalToConstant: 52
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        writeTouchTarget()
    }

    deinit {
        timer?.invalidate()
    }

    @objc dynamic func smokeMessage() -> String {
        "BEFORE"
    }

    @objc private func didReplayTouch() {
        guard let marker = documentURL(
            named: "agentInjection-touch.txt"
        ) else {
            return
        }

        try? "TOUCHED".write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
    }

    private func refreshSmokeState() {
        let message = smokeMessage()
        statusLabel.text = message

        guard let marker = documentURL(
            named: "agentInjection-smoke.txt"
        ) else {
            return
        }

        try? message.write(
            to: marker,
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeTouchTarget() {
        guard touchButton.window != nil,
              let target = documentURL(
                named: "agentInjection-touch-target.json"
              ) else {
            return
        }

        let center = touchButton.convert(
            CGPoint(
                x: touchButton.bounds.midX,
                y: touchButton.bounds.midY
            ),
            to: nil
        )
        let payload: [String: Double] = [
            "x": center.x,
            "y": center.y
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload
        ) else {
            return
        }

        try? data.write(
            to: target,
            options: .atomic
        )
    }

    private func documentURL(
        named name: String
    ) -> URL? {
        FileManager.default
            .urls(
                for: .documentDirectory,
                in: .userDomainMask
            )
            .first?
            .appendingPathComponent(name)
    }
}
