import UIKit

/// 已保存会话的列表：显示名称、时间、序列数和笔划数，支持导出 zip 和删除。
final class SessionListViewController: UITableViewController {
    var onClose: (() -> Void)?

    private var sessions: [SessionSummary] = []
    private var isExporting = false
    private let cellIdentifier = "session"

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "会话列表"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(closeTapped)
        )
        reload()
    }

    private func reload() {
        sessions = SessionStore.listSessions()
        tableView.reloadData()
        if sessions.isEmpty {
            let label = UILabel()
            label.text = "还没有已保存的会话"
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            tableView.backgroundView = label
        } else {
            tableView.backgroundView = nil
        }
    }

    @objc private func closeTapped() {
        let onClose = self.onClose
        dismiss(animated: true) {
            onClose?()
        }
    }

    // MARK: - UITableViewDataSource

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sessions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: cellIdentifier)
        let summary = sessions[indexPath.row]
        cell.textLabel?.text = summary.name
        cell.detailTextLabel?.text = summary.detailText
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let summary = sessions[indexPath.row]
        let sheet = UIAlertController(title: summary.name, message: summary.folderName, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "导出 zip…", style: .default) { [weak self] _ in
            self?.export(summary, at: indexPath)
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.confirmDelete(summary)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configurePopover(sheet.popoverPresentationController, at: indexPath)
        present(sheet, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let summary = sessions[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            completion(true)
            self?.delete(summary)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - 操作

    private func confirmDelete(_ summary: SessionSummary) {
        let alert = UIAlertController(
            title: "删除会话？",
            message: "将永久删除 \(summary.folderName)。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.delete(summary)
        })
        present(alert, animated: true)
    }

    private func delete(_ summary: SessionSummary) {
        do {
            try SessionStore.deleteSession(at: summary.url)
        } catch {
            showError(title: "删除失败", error: error)
        }
        reload()
    }

    private func export(_ summary: SessionSummary, at indexPath: IndexPath) {
        guard !isExporting else { return }
        isExporting = true
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: spinner)

        let folder = summary.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result<URL, Error>(catching: { try Zipper.zipSessionFolder(folder) })
            DispatchQueue.main.async {
                self?.finishExport(result, at: indexPath)
            }
        }
    }

    private func finishExport(_ result: Result<URL, Error>, at indexPath: IndexPath) {
        isExporting = false
        navigationItem.leftBarButtonItem = nil
        switch result {
        case .success(let zipURL):
            let activity = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: zipURL)
            }
            configurePopover(activity.popoverPresentationController, at: indexPath)
            present(activity, animated: true)
        case .failure(let error):
            showError(title: "导出失败", error: error)
        }
    }

    private func configurePopover(_ popover: UIPopoverPresentationController?, at indexPath: IndexPath) {
        guard let popover = popover else { return }
        if let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        } else {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
    }

    private func showError(title: String, error: Error) {
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
