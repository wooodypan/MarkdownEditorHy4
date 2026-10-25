//
//  MarkdownToast.swift
//  MarkdownEditorHy4
//
//  轻提示：屏幕下方浮一个小药丸，一秒半之后自己淡出。
//
//  ### 为什么在 App 层，不在 MarkdownEditor 库里
//  库的边界是 markdown 源码 ↔ 渲染/编辑。提示条长什么样、离底多少、活多久，全是宿主的展示策略。
//  库那边只留了一个出口 `MarkdownTextView.onStatusMessage`：什么时候该说话由它决定，怎么说由这里决定。
//
//  ### 为什么不引第三方库
//  `doc/Toast.md` 里写过：多数 toast 库是按 iOS 那一套（键盘避让、底部安全区、边缘手势）写的，Mac Catalyst 上这些基本用不上，位置和动画还容易跟系统对不齐；这点功能不值得多背一个依赖。
//
//  ### 三条使用约定
//  1. 挂在 window 或者页面根视图上，别加进 MarkdownTextView —— 那样提示会跟着正文一起滚走。
//  2. 同一时刻只留一条：连着调也只会有一条，见 `show` 里那两段处理。
//  3. 纯展示，不挡点击（`isUserInteractionEnabled = false`），免得盖住正文底部的链接和复选框。
//
//  ### 夜间模式
//  底色是动态色，跟随系统（以及 App 里「外观模式」选的那一档）自动切换深浅；
//  文字固定白色 —— 两种模式的底色都压得够深，白字对比度都在 5:1 以上。
//

import UIKit

/// 一个很轻的提示条，用法只有一行：
///
/// ```swift
/// MarkdownToast.show("已清除文本格式", in: window)
/// ```
enum MarkdownToast {

    /// 一条提示在屏幕上停留多久（秒），从淡入完成那一刻开始算，不含淡出的那 0.25 秒。
    static var duration: TimeInterval = 1.5

    /// 挂在提示视图上的标识。
    ///
    /// 不只是给自动化测试用：排查「提示没出来」的时候，把宿主视图的 subviews 打出来就能一眼认出哪一个是它，不用猜那个没有类名的深色小方块是什么。
    static let viewIdentifier = "MarkdownEditorHy4.MarkdownToast"

    /// 当前屏幕上那一条。
    ///
    /// 用弱引用：宿主视图被销毁（关窗、退出全屏页）时它跟着走，不会留一个看不见却还活着的引用。
    private static weak var current: MarkdownToastView?

    /// 弹一条提示。
    ///
    /// - parameters:
    ///   - message: 提示文案。空串直接忽略 —— 弹一个没有字的空药丸没有意义。
    ///   - host: 挂在谁身上，传 window 最稳（见文件头第 1 条约定）。
    /// - returns: 有没有真的显示。宿主是 nil（比如还没进窗口、或者在离屏视图里）时返回 false。
    @discardableResult
    static func show(_ message: String, in host: UIView?) -> Bool {
        guard let host, !message.isEmpty else { return false }

        // 同一句话还挂在屏幕上：只把倒计时重新排一遍。
        // 先删再建会闪一下，连按快捷键时屏幕上像在抽搐
        if let current, current.message == message, current.superview === host {
            current.restartCountdown()
            return true
        }

        // 换了文案或者换了宿主：上一条立刻撤掉，避免两条叠在一起互相压着
        current?.removeFromSuperview()

        let toast = MarkdownToastView(message: message)
        host.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            // 两边各留 16 点：窗口再窄也不会顶到边缘
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
            // 宽屏保护：最多占 80% 宽，绝对上限 400 点。不然一句短提示会在 27 寸屏上摊成一条长带子
            toast.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.8),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])
        current = toast

        toast.present()
        // 看不到药丸的人（VoiceOver）只能靠这一句，所以念一遍是必须的
        UIAccessibility.post(notification: .announcement, argument: message)
        return true
    }
}

/// 药丸本体。外面只通过 `MarkdownToast.show` 用它，不直接碰。
private final class MarkdownToastView: UIView {

    /// 这条提示的文案。重复调用时靠它判断「是不是同一句话」。
    let message: String

    /// 还没到点的倒计时。
    ///
    /// 每次重排都换一个新的任务、旧的先取消：不然连续调用会留下好几个计时器，最后一个到点时把刚弹出来的新提示提前收走。
    private var pendingHide: DispatchWorkItem?

    /// 是不是正在淡出。
    ///
    /// 淡出要 0.25 秒，这期间视图还在宿主上。要是这时候又来一次同样的提示，
    /// 不把淡出掐掉的话，它会在半透明状态被上一条的收尾动作删掉 —— 用户看到的是「第二下没反应」。
    private var isFadingOut = false

    init(message: String) {
        self.message = message
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        // 只是提示，别把正文的点击吃掉（它正好盖在页面底部中央）
        isUserInteractionEnabled = false
        accessibilityIdentifier = MarkdownToast.viewIdentifier
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        // 夜间模式的关键：动态色会在深浅色切换时自动重新解析，不需要我们监听什么通知。
        // 浅色模式用接近黑的深灰（铺在白色正文上足够醒目）；深色模式要提亮到 0.3 灰 —— 页面底色本身只有 0.11 左右，用 0.25 以下会跟背景糊成一片，看不出这里有个药丸
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.30, alpha: 0.96)
                : UIColor(white: 0.12, alpha: 0.90)
        }

        let label = UILabel()
        label.text = message
        // 两种模式的底色都是深的，白字都能读，所以文字不跟着变
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownToastView 不支持从 coder 解档")
    }

    /// 淡入，并开始倒计时。
    func present() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            // 开了「减弱动态效果」就直接显形。
            // 这不是洁癖：这个开关的意思就是「别给我渐变和位移」，对这类用户淡入反而难受
            alpha = 1
            restartCountdown()
            return
        }
        alpha = 0
        UIView.animate(withDuration: 0.2) {
            self.alpha = 1
        } completion: { _ in
            self.restartCountdown()
        }
    }

    /// 重新排一次倒计时（重复调用时走这里）。
    func restartCountdown() {
        guard superview != nil else { return }

        // 正好在淡出：把淡出掐掉、拉回不透明，不然下面那个收尾动作会在几百毫秒后把它删了。
        // 注意顺序：先清标记再停动画 —— 停动画会立刻回调 completion，它会看这个标记决定删不删自己
        if isFadingOut {
            isFadingOut = false
            layer.removeAllAnimations()
            alpha = 1
        }

        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MarkdownToast.duration, execute: work)
    }

    /// 淡出，淡完从宿主上摘掉。
    private func dismiss() {
        pendingHide = nil
        guard superview != nil, !isFadingOut else { return }
        isFadingOut = true
        guard !UIAccessibility.isReduceMotionEnabled else {
            removeFromSuperview()
            return
        }
        UIView.animate(withDuration: 0.25, animations: {
            self.alpha = 0
        }, completion: { _ in
            // 淡出这 0.25 秒里如果又弹了同一条，`restartCountdown` 已经把 isFadingOut 清掉，
            // 这里就不能再删自己了（换了文案的情况走的是「立刻删旧的、另建一条」，不受影响）
            guard self.isFadingOut else { return }
            self.removeFromSuperview()
        })
    }
}
