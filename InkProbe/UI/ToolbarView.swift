import UIKit

/// 顶部工具栏：只包含应用自身的功能，绘图工具全部由系统 PKToolPicker 提供。
final class ToolbarView: UIView {
    var onPencilOnlyChanged: ((Bool) -> Void)?
    var onSnapshotsChanged: ((Bool) -> Void)?
    var onLoggingChanged: ((Bool) -> Void)?
    var onNewSession: (() -> Void)?
    var onSave: (() -> Void)?
    var onShowSessions: (() -> Void)?

    let statusLabel = UILabel()

    private let pencilOnlySwitch = UISwitch()
    private let snapshotsSwitch = UISwitch()
    private let loggingSwitch = UISwitch()
    private let newSessionButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let sessionsButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setControlsEnabled(_ enabled: Bool) {
        for control in [pencilOnlySwitch, snapshotsSwitch, loggingSwitch, newSessionButton, saveButton, sessionsButton] as [UIControl] {
            control.isEnabled = enabled
        }
    }

    private func setUp() {
        backgroundColor = UIColor(white: 0.97, alpha: 1)

        pencilOnlySwitch.isOn = true
        snapshotsSwitch.isOn = true
        loggingSwitch.isOn = true
        pencilOnlySwitch.addTarget(self, action: #selector(pencilOnlyChanged), for: .valueChanged)
        snapshotsSwitch.addTarget(self, action: #selector(snapshotsChanged), for: .valueChanged)
        loggingSwitch.addTarget(self, action: #selector(loggingChanged), for: .valueChanged)

        configure(newSessionButton, title: "新会话", action: #selector(newSessionTapped))
        configure(saveButton, title: "结束并保存", action: #selector(saveTapped))
        configure(sessionsButton, title: "会话列表", action: #selector(sessionsTapped))

        let controls = UIStackView(arrangedSubviews: [
            labeled("仅 Pencil 绘图", pencilOnlySwitch),
            labeled("逐步快照", snapshotsSwitch),
            labeled("记录输入", loggingSwitch),
            newSessionButton,
            saveButton,
            sessionsButton
        ])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = 20
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        statusLabel.textColor = .darkGray
        statusLabel.textAlignment = .right
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.7
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let separator = UIView()
        separator.backgroundColor = UIColor(white: 0.8, alpha: 1)
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(controls)
        addSubview(statusLabel)
        addSubview(separator)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: controls.trailingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
        ])
    }

    private func labeled(_ title: String, _ control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 15)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        return stack
    }

    private func configure(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func pencilOnlyChanged() {
        onPencilOnlyChanged?(pencilOnlySwitch.isOn)
    }

    @objc private func snapshotsChanged() {
        onSnapshotsChanged?(snapshotsSwitch.isOn)
    }

    @objc private func loggingChanged() {
        onLoggingChanged?(loggingSwitch.isOn)
    }

    @objc private func newSessionTapped() {
        onNewSession?()
    }

    @objc private func saveTapped() {
        onSave?()
    }

    @objc private func sessionsTapped() {
        onShowSessions?()
    }
}

/// 保存期间的进度提示，覆盖整个界面并拦截触摸。
final class ProgressHUD: UIView {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.25)

        let box = UIView()
        box.backgroundColor = .white
        box.layer.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false

        label.font = UIFont.systemFont(ofSize: 15)
        label.textColor = .black
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(box)
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(in parent: UIView, text: String) {
        frame = parent.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.text = text
        parent.addSubview(self)
        spinner.startAnimating()
    }

    func setText(_ text: String) {
        label.text = text
    }

    func hide() {
        spinner.stopAnimating()
        removeFromSuperview()
    }
}
