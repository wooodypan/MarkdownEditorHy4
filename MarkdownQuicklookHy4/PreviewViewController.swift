//
//  PreviewViewController.swift
//  MarkdownQuicklookHy4
//
//  Created by pan on 2026/10/13.
//

import UIKit
import QuickLook

/// ⚠️ 当前没被用到 —— Info.plist 里走的是 PreviewProvider（数据型），系统不会加载这个类。
///
/// 这是 Xcode 模板一起生成的「视图型」骨架，留着当参考：哪天想自己画预览界面（比如要塞原生控件、做交互），就把 Info.plist 里的入口换回 NSExtensionMainStoryboard 指向 MainInterface。
/// 两条路只能走一条，别同时开 —— 同时开的时候系统按 plist 里的键决定用谁，很容易出现「改了半天这里不生效」的迷惑场面。
class PreviewViewController: UIViewController, QLPreviewingController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }

    /*
    func preparePreviewOfSearchableItem(identifier: String, queryString: String?) async throws {
        // Implement this method and set QLSupportsSearchableItems to YES in the Info.plist of the extension if you support CoreSpotlight.

        // Perform any setup necessary in order to prepare the view.
        // Quick Look will display a loading spinner until this returns.
    }
    */

    func preparePreviewOfFile(at url: URL) async throws {
        // Add the supported content types to the QLSupportedContentTypes array in the Info.plist of the extension.

        // Perform any setup necessary in order to prepare the view.

        // Quick Look will display a loading spinner until this returns.
    }

}
