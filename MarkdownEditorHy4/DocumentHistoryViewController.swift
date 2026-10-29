//
//  DocumentHistoryViewController.swift
//  MarkdownEditorHy4
//
//  历史版本那一页：上面一行「保存当前版本」，下面是版本列表，点某一版能看正文、能恢复。
//
//  大白话：这就是"存档柜"的门——打开它能看到以前存过哪些版本，挑一份拿回来。
//
//  这一页只认识"文件地址 + 一个历史仓库"，不认识编辑器，也不自己去动正文：
//  恢复出来的内容交给外面（编辑页）去套用。这样"恢复"和"换文档""重载"走的是同一条路，不会多出一套说法。
//
//  ### 为什么恢复之后不直接写盘
//  恢复是"把编辑器里的内容换成旧版"，换完文档处于"已修改、还没存"的状态，用户还能再看一眼、再改两笔，或者反悔（恢复前那一版已经自动存了档）。
//  直接写盘等于替用户做了"确定要覆盖文件"这个决定，太激进。
//

import UIKit

/// 历史页里一次操作的结果，相当于一张"回执单"：谁在最上面，谁来念给用户听。
///
/// ### 为什么是"把结果交回来"，而不是让编辑页顺手弹个框
/// 历史页是盖在编辑页上面的一层。编辑页在下面再 `present` 一个提示框时，UIKit 会因为它"已经 present 着历史页"而把新框直接丢掉（控制台只留一句 warning），用户什么都看不到 ——包括"恢复前的备份没存上"这种必须让用户知道的事。
/// 所以操作只负责做事，结果交回给当前最上层的这一页来显示。
enum DocumentHistoryFeedback {

    /// 手动存了一版
    case saved(sequence: Int)
    /// 恢复成功，编辑器里的内容已经换掉了
    case restored
    /// 恢复成功，但恢复前那份内容没存上（次要失败，但必须让用户知道）
    case restoredWithoutBackup(message: String)
    /// 整件事没做成
    case failed(title: String, message: String)

    /// 列表顶上那条横幅写什么
    var bannerText: String {
        switch self {
        case .saved(let sequence):
            return "已存为版本 #\(sequence)，这一版不会被自动清理。"
        case .restored:
            return "已恢复到这一版，还没存盘（按 ⌘S 保存）。恢复前的内容已经留了一版。"
        case .restoredWithoutBackup(let message):
            return "已恢复，但恢复前的内容没能留档：\(message)"
        case .failed(let title, let message):
            return "\(title)：\(message)"
        }
    }

    /// 要不要标红（失败、或者需要用户留意的半失败）
    var isFailure: Bool {
        switch self {
        case .saved, .restored: return false
        case .restoredWithoutBackup, .failed: return true
        }
    }
}

/// 历史版本列表页，也就是用户点「历史版本」后看到的那张表。
///
/// 用的时候包一层 `UINavigationController` 再 present 出来，这样才有地方放「完成」按钮、也才能 push 进预览页。
final class DocumentHistoryViewController: UIViewController {

    private let fileURL: URL
    private let store: DocumentHistoryStore
    private var versions: [DocumentVersion] = []

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// 用户在预览页点了「恢复」：把版本的 id 报给编辑页，真正动手的是它。
    /// - Returns: 这次恢复的结果，由本页显示；编辑页已经关掉时回 nil
    var onRestoreVersion: ((UUID) -> DocumentHistoryFeedback?)?
    /// 用户点了「保存当前版本」：报给编辑页去存，只有它知道编辑器里此刻是什么内容。
    /// - Returns: 这次保存的结果，由本页显示；编辑页已经关掉时回 nil
    var onSaveCurrentVersion: (() -> DocumentHistoryFeedback?)?
    /// 问编辑页要"编辑器里现在写的是什么"。
    ///
    /// 点进某一版时，拿它跟那一版比，用户就能看见"点恢复会改掉哪些行"。
    /// 用闭包而不是打开这一页时就把文字拷一份：内容一直活在编辑器里，随时要最新的一份最省心。
    var currentContent: (() -> String?)?
    /// 清单坏掉、读不出来时，把原因记在这儿，显示在空白的列表中间
    private var loadErrorMessage: String?
    /// 最近一次操作的结果，显示成列表顶上的一条横幅。
    ///
    /// 不弹框：在「恢复」的确认框还没收完时再弹新框，UIKit 会把新的那个丢掉；
    /// 而且横幅会一直留在那儿，用户回头还能看见刚才发生了什么。
    private var banner: DocumentHistoryFeedback?

    /// - Parameters:
    ///   - fileURL: 这份文档在磁盘上的位置
    ///   - store: 历史仓库。默认用 App 那一个，测试可以传一个指向临时目录的
    init(fileURL: URL, store: DocumentHistoryStore = .shared) {
        self.fileURL = fileURL
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentHistoryViewController 不支持从 coder 解档")
    }

    /// 原因见 `MarkdownBlock` / `OutlineCoordinator` 里 `nonisolated deinit` 那段长注释。
    /// 这个类除了几个 UIView，持有的都是值类型和常量，声明成 nonisolated 完全安全。
    nonisolated deinit {}

    /// 列表上"什么时候存的"怎么显示成一行字。
    ///
    /// 特意做成 `static`：整个列表共用这一个 —— `DateFormatter` 造一次挺贵，每行造一个会拖慢滚动。
    /// 预览页也要用它显示标题，所以没写 `private`。
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // short / short 是"跟着系统语言走"的格式，中文下大概是「2026/9/29 01:07」
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "历史版本"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(closeTapped))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        reloadVersions()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: 数据

    /// 重新读一遍清单，把列表刷成最新的样子。
    ///
    /// 存了新版本、恢复过、或者用户点了「保存当前版本」之后都要走一趟，不然列表上还是上一次看到的那些行。
    func reloadVersions() {
        do {
            versions = try store.versions(fileAt: fileURL)
            loadErrorMessage = nil
        } catch {
            // 清单读不出来时既不崩、也不假装"没有历史"：把原因显示在空态里，用户才知道是历史坏了，而不是"App 从来没给我存过档"
            versions = []
            loadErrorMessage = error.localizedDescription
        }
        applyEmptyState()
        tableView.reloadData()
    }

    /// 一行也没有时，在列表中间说一句话（说明什么时候会自动存档，或者历史为什么读不出来）。
    private func applyEmptyState() {
        // 有横幅的时候不铺这层说明：横幅已经把"刚才那次操作怎么了"讲清楚了，两段字叠在一起只会互相打架
        guard versions.isEmpty, banner == nil else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 14)
        label.text = loadErrorMessage
            ?? "这份文档还没有历史版本。\n\n停止输入约 30 秒、按 ⌘S 存盘、切走 App 或者离开这一页时，"
             + "App 会自动留一份档；想留住某个时刻，就点上面的「保存当前版本」。"
        tableView.backgroundView = label
    }

    /// 点「保存当前版本」：交给编辑页去存，结果挂到列表顶上
    private func saveCurrentVersion() {
        presentBanner(onSaveCurrentVersion?())
    }

    /// 把一次操作的结果挂到列表顶上。
    ///
    /// 挂完滚回顶部：用户可能是在列表底下翻到某一版再恢复的，不滚上去就看不见这条说明。
    private func presentBanner(_ feedback: DocumentHistoryFeedback?) {
        banner = feedback
        reloadVersions()
        guard feedback != nil else { return }
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
    }

    /// 恢复之前先问一句：这一步会把编辑器里现在的内容整个换掉。
    ///
    /// 大白话：动手前先打个招呼——"要覆盖现在的内容了，不过我会先帮你把现在这份存起来"。
    private func confirmRestore(_ version: DocumentVersion) {
        let alert = UIAlertController(
            title: "恢复到这一版？",
            message: "编辑器里现在的内容会被换成 \(Self.dateFormatter.string(from: version.createdAt)) 那一版。\n\n"
                   + "现在这份内容会先自动留一版，想反悔可以再从列表里找回它。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "恢复", style: .default) { [weak self] _ in
            guard let self else { return }
            self.presentBanner(self.onRestoreVersion?(version.id))
            // 恢复完从预览页退回列表（等确认框这一拍收完再退，免得两个转场挤在一起）。
            // 预览页显示的永远是那一版的旧内容，留在那儿会让人以为没恢复成功；
            // 失败 / 备份没存上的提示也在列表顶上那条横幅里，得让用户看得见
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let navigationController = self.navigationController,
                      navigationController.topViewController !== self else { return }
                navigationController.popToViewController(self, animated: true)
            }
        })
        present(alert, animated: true)
    }

    /// 点某一版：读正文 → 进预览页。
    ///
    /// 读不出来（文件被清掉、不是 UTF-8）就当场说一句，不让用户点进一个空白页去瞎猜。
    private func showVersion(_ version: DocumentVersion) {
        let text: String
        do {
            text = try store.content(fileAt: fileURL, versionID: version.id)
        } catch {
            showAlert(title: "读不出这一版", message: error.localizedDescription)
            return
        }
        let preview = DocumentVersionPreviewController(version: version,
                                                      content: text,
                                                      currentContent: currentContent?() ?? "")
        preview.onConfirm = { [weak self] in self?.confirmRestore(version) }
        navigationController?.pushViewController(preview, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - 列表数据

extension DocumentHistoryViewController: UITableViewDataSource, UITableViewDelegate {

    /// 列表分几段：可能先有一条"刚才那次操作"的横幅，然后「保存当前版本」，最后是版本列表。
    ///
    /// 有横幅时它占掉第 0 段，后面的段号整体往后挪一位 —— 所以下面所有取段号的地方都得走这几个计算属性，别写死数字。
    private var hasBanner: Bool { banner != nil }
    private var saveSection: Int { hasBanner ? 1 : 0 }
    private var versionsSection: Int { hasBanner ? 2 : 1 }

    /// 为什么不把「保存当前版本」做成导航栏上的按钮：那儿的按钮是「完成」，再塞一个进去，Mac 上两个按钮挤在右上角容易误点；而且"保存版本"和"关闭"本来就不是一类动作。
    func numberOfSections(in tableView: UITableView) -> Int { hasBanner ? 3 : 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if hasBanner, section == 0 { return 1 }
        return section == versionsSection ? versions.count : 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // 第 0 段（有横幅时）：刚才那次操作的结果
        if hasBanner, indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: "操作结果")
            cell.textLabel?.text = banner?.bannerText
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.font = .systemFont(ofSize: 14)
            cell.textLabel?.textColor = banner?.isFailure == true ? .systemRed : .secondaryLabel
            // 这只是一句说明，不是能点的行
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.section == saveSection {
            let cell = UITableViewCell(style: .default, reuseIdentifier: "保存")
            cell.textLabel?.text = "保存当前版本"
            cell.imageView?.image = UIImage(systemName: "plus.circle")
            return cell
        }

        let version = versions[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "版本")
        cell.textLabel?.text = Self.dateFormatter.string(from: version.createdAt)
        // 最新那一版标一下：它本来就排在最上面，但写清楚更省得用户自己猜
        let prefix = indexPath.row == 0 ? "最新 · " : ""
        cell.detailTextLabel?.text = prefix + version.reason.displayName + " · " + version.sizeText
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if hasBanner, indexPath.section == 0 { return }
        if indexPath.section == saveSection {
            saveCurrentVersion()
        } else {
            showVersion(versions[indexPath.row])
        }
    }
}

// MARK: - 一行上显示的东西

extension DocumentVersion {

    /// 这一版有多大，显示成「4 KB」这种一眼能看懂的样子。
    ///
    /// 数的是 UTF-8 字节数，跟文件在磁盘上占的空间对得上（清单里记的就是这个数）。
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
